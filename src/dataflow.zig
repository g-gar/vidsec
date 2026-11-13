//! Flowdata Reactive Dataflow Library (`flowdata_dataflow`).
//!
//! Standalone, zero-dependency reactive dataflow library providing zero-copy `PayloadHandle`
//! streams, compile-time struct reflection (`ReflectedValue`), relational stream algebra
//! (`merge`, `zip`, `join`, `slice`), declarative predicate filtering, data-parallel lifting
//! (`wrapElemental`, `wrapExpansion`, `wrapReduction`), and multi-channel stream dispatching.

const std = @import("std");

pub const dataflow = @import("dataflow/mod.zig");

pub const types = dataflow.types;
pub const ReflectedValue = dataflow.ReflectedValue;
pub const ReflectFn = dataflow.types.ReflectFn;
pub const ContextualReflectFn = dataflow.types.ContextualReflectFn;
pub const reflectField = dataflow.reflectField;
pub const reflectAny = dataflow.reflectAny;
pub const PayloadHandle = dataflow.PayloadHandle;
pub const PayloadRepr = dataflow.PayloadRepr;
pub const DynamicField = dataflow.DynamicField;
pub const DynamicRecord = dataflow.DynamicRecord;

pub const algebra = dataflow.algebra;
pub const merge = dataflow.merge;
pub const zip = dataflow.zip;
pub const join = dataflow.join;
pub const slice = dataflow.slice;
pub const slicePayload = dataflow.slicePayload;
pub const mergePayloads = dataflow.mergePayloads;
pub const Pair = dataflow.Pair;
pub const Joined = dataflow.Joined;

pub const predicate = dataflow.predicate;
pub const evaluatePredicate = dataflow.evaluatePredicate;
pub const evaluatePredicateHandle = dataflow.evaluatePredicateHandle;
pub const filterStream = dataflow.filterStream;
pub const filterPayload = dataflow.filterPayload;

pub const parallel = dataflow.parallel;
pub const parallelFor = dataflow.parallelFor;
pub const ParallelError = dataflow.ParallelError;

pub const lifter = dataflow.lifter;
pub const ExecutionOptions = dataflow.ExecutionOptions;
pub const ErasedTaskFn = dataflow.ErasedTaskFn;
pub const wrapElemental = dataflow.wrapElemental;
pub const wrapExpansion = dataflow.wrapExpansion;
pub const wrapReduction = dataflow.wrapReduction;
pub const wrapBatch = dataflow.wrapBatch;

pub const dispatcher = dataflow.dispatcher;
pub const ChannelSpec = dataflow.ChannelSpec;
pub const DispatchedChannel = dataflow.DispatchedChannel;
pub const dispatchStream = dataflow.dispatchStream;

// 009A: Predicate AST
pub const predicate_ast = dataflow.predicate_ast;
pub const PredicateNode = dataflow.PredicateNode;
pub const PredicateParser = dataflow.PredicateParser;
pub const PredicateBuilder = dataflow.PredicateBuilder;
pub const Literal = dataflow.Literal;
pub const CmpOp = dataflow.CmpOp;
pub const FieldGetter = dataflow.FieldGetter;
pub const evalPredicateNode = dataflow.evalPredicateNode;

test {
    std.testing.refAllDecls(@This());
}
