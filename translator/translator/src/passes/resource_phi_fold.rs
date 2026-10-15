// Apple's GL compiles a GLSL function that takes a sampler2D (Minecraft's `sample_lightmap(sampler2D, ivec2)`) by
// passing every texture/sampler pair the shader binds plus the index of the one meant, and choosing with a switch:
//
//     store i32 0, ptr %which                        ; the caller: Sampler2 is pair 0
//     %i = load i32, ptr %which                      ; the inlined helper
//     switch i32 %i, label %merge [ i32 1, label %case ]
//     merge: %tex = phi ptr addrspace(1) [ %t0, %block ], [ %t1, %case ]
//            %smp = phi ptr addrspace(2) [ %s0, %block ], [ %s1, %case ]
//
// The emitter turns each candidate into a loaded image/sampler and the phis keep LLVM's pointer type, so the sample
// lowering finds a sampler operand it cannot recover ("sampler operand is a pointer whose exact sampler state was not
// recovered") and the vertex shader fails: Apple's GL then runs it on the CPU. The selector is a constant, stored
// once into a function variable; this pass evaluates the branch that feeds such a phi and replaces the phi by the
// value on the edge that is taken. Phis of other types, and branches whose condition is not a constant, are left
// alone.
use crate::spirv_module::{Instruction, Operand};
use spirv::{Op, StorageClass, Word};
use std::collections::{HashMap, HashSet};

use super::Ctx;

pub(super) fn fold_constant_resource_phis(ctx: &mut Ctx, entry_idx: usize) -> usize {
    let globals: Vec<&Instruction> = ctx.module.types_global_values.iter().chain(ctx.new_globals.iter()).collect();
    let opaque_types: HashSet<Word> = globals
        .iter()
        .filter(|i| matches!(i.class.opcode, Op::TypeImage | Op::TypeSampler | Op::TypeSampledImage))
        .filter_map(|i| i.result_id)
        .collect();
    let function = &ctx.module.functions[entry_idx];
    let defs: HashMap<Word, &Instruction> = globals
        .iter()
        .copied()
        .chain(function.blocks.iter().flat_map(|b| b.instructions.iter()))
        .filter_map(|i| Some((i.result_id?, i)))
        .collect();
    let eval = Eval::new(function.blocks.iter().flat_map(|b| b.instructions.iter()), &defs);
    let label = |b: &crate::spirv_module::Block| b.label.as_ref().and_then(|l| l.result_id);
    let terminators: HashMap<Word, &Instruction> =
        function.blocks.iter().filter_map(|b| Some((label(b)?, b.instructions.last()?))).collect();
    let mut preds: HashMap<Word, Vec<Word>> = HashMap::new();
    for (&block, term) in &terminators {
        for target in branch_targets(term) {
            preds.entry(target).or_default().push(block);
        }
    }

    let mut replace: HashMap<Word, Word> = HashMap::new();
    for block in &function.blocks {
        let Some(merge) = label(block) else { continue };
        for phi in block.instructions.iter().take_while(|i| i.class.opcode == Op::Phi) {
            let (Some(result), Some(_)) = (phi.result_id, phi.result_type) else { continue };
            let incoming: Vec<(Word, Word)> = phi
                .operands
                .chunks(2)
                .filter_map(|pair| match pair {
                    [Operand::IdRef(v), Operand::IdRef(b)] => Some((*v, *b)),
                    _ => None,
                })
                .collect();
            if incoming.len() < 2
                || !incoming.iter().all(|(v, _)| defs.get(v).and_then(|d| d.result_type).is_some_and(|t| opaque_types.contains(&t)))
            {
                continue;
            }
            // every edge leaves the same header, directly or through a block that only branches on to the merge
            let header_of = |pred: Word| -> Option<Word> {
                let term = terminators.get(&pred)?;
                if term.class.opcode == Op::Branch {
                    match preds.get(&pred).map(Vec::as_slice) {
                        Some([only]) => Some(*only),
                        _ => None,
                    }
                } else {
                    Some(pred)
                }
            };
            let headers: HashSet<Option<Word>> = incoming.iter().map(|(_, p)| header_of(*p)).collect();
            let [Some(header)] = headers.into_iter().collect::<Vec<_>>()[..] else { continue };
            let Some(taken) = terminators.get(&header).and_then(|t| eval.taken_target(t)) else { continue };
            let chosen = incoming
                .iter()
                .find(|(_, pred)| if taken == merge { *pred == header } else { *pred == taken })
                .map(|(v, _)| *v);
            if let Some(value) = chosen {
                replace.insert(result, value);
            }
        }
    }
    if replace.is_empty() {
        return 0;
    }
    let function = &mut ctx.module.functions[entry_idx];
    for block in &mut function.blocks {
        block.instructions.retain(|i| !i.result_id.is_some_and(|r| replace.contains_key(&r)));
        for inst in &mut block.instructions {
            for operand in &mut inst.operands {
                if let Operand::IdRef(id) = operand {
                    let mut to = *id;
                    while let Some(next) = replace.get(&to) {
                        to = *next;
                    }
                    *id = to;
                }
            }
        }
    }
    replace.len()
}

fn branch_targets(term: &Instruction) -> Vec<Word> {
    let ids = |range: &[Operand]| range.iter().filter_map(|o| match o { Operand::IdRef(id) => Some(*id), _ => None }).collect();
    match term.class.opcode {
        Op::Branch => ids(&term.operands),
        Op::BranchConditional => ids(term.operands.get(1..3).unwrap_or(&[])),
        Op::Switch => ids(term.operands.get(1..).unwrap_or(&[])),
        _ => vec![],
    }
}

// Integer and boolean values known at translation time: constants, and loads of a function variable that holds one
// stored constant and is otherwise only loaded (an alloca whose address never escapes).
struct Eval<'a> {
    defs: &'a HashMap<Word, &'a Instruction>,
    stored: HashMap<Word, Word>,
}

impl<'a> Eval<'a> {
    fn new(insts: impl Iterator<Item = &'a Instruction>, defs: &'a HashMap<Word, &'a Instruction>) -> Self {
        let mut stores: HashMap<Word, Vec<Word>> = HashMap::new();
        let mut escaped: HashSet<Word> = HashSet::new();
        for inst in insts {
            match (inst.class.opcode, inst.operands.as_slice()) {
                (Op::Store, [Operand::IdRef(ptr), Operand::IdRef(value), ..]) => {
                    stores.entry(*ptr).or_default().push(*value);
                    escaped.insert(*value);
                }
                (Op::Load, [Operand::IdRef(_), ..]) => {}
                _ => escaped.extend(inst.operands.iter().filter_map(|o| match o { Operand::IdRef(id) => Some(*id), _ => None })),
            }
        }
        let is_function_var = |ptr: &Word| {
            defs.get(ptr).is_some_and(|d| {
                d.class.opcode == Op::Variable && d.operands.first() == Some(&Operand::StorageClass(StorageClass::Function))
            })
        };
        let stored = stores
            .into_iter()
            .filter(|(ptr, values)| values.len() == 1 && is_function_var(ptr) && !escaped.contains(ptr))
            .map(|(ptr, values)| (ptr, values[0]))
            .collect();
        Eval { defs, stored }
    }

    fn int(&self, id: Word) -> Option<u64> {
        let d = self.defs.get(&id)?;
        match (d.class.opcode, d.operands.as_slice()) {
            (Op::Constant, [Operand::LiteralBit32(v)]) => Some(u64::from(*v)),
            (Op::Constant, [Operand::LiteralBit64(v)]) => Some(*v),
            (Op::ConstantNull, []) => Some(0),
            (Op::Load, [Operand::IdRef(ptr), ..]) => self.int(*self.stored.get(ptr)?),
            _ => None,
        }
    }

    fn bool(&self, id: Word) -> Option<bool> {
        let d = self.defs.get(&id)?;
        match (d.class.opcode, d.operands.as_slice()) {
            (Op::ConstantTrue, []) => Some(true),
            (Op::ConstantFalse, []) => Some(false),
            (Op::IEqual, [Operand::IdRef(a), Operand::IdRef(b)]) => Some(self.int(*a)? == self.int(*b)?),
            (Op::INotEqual, [Operand::IdRef(a), Operand::IdRef(b)]) => Some(self.int(*a)? != self.int(*b)?),
            (Op::LogicalNot, [Operand::IdRef(a)]) => Some(!self.bool(*a)?),
            (Op::Load, [Operand::IdRef(ptr), ..]) => self.bool(*self.stored.get(ptr)?),
            _ => None,
        }
    }

    fn taken_target(&self, term: &Instruction) -> Option<Word> {
        match (term.class.opcode, term.operands.as_slice()) {
            (Op::BranchConditional, [Operand::IdRef(cond), Operand::IdRef(t), Operand::IdRef(f), ..]) => {
                Some(if self.bool(*cond)? { *t } else { *f })
            }
            (Op::Switch, [Operand::IdRef(selector), Operand::IdRef(default), cases @ ..]) => {
                let value = self.int(*selector)?;
                let mut target = *default;
                for case in cases.chunks(2) {
                    let literal = match case.first()? {
                        Operand::LiteralBit32(v) => u64::from(*v),
                        Operand::LiteralBit64(v) => *v,
                        _ => return None,
                    };
                    if literal == value {
                        let Operand::IdRef(t) = case.get(1)? else { return None };
                        target = *t;
                    }
                }
                Some(target)
            }
            _ => None,
        }
    }
}
