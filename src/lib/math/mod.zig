const std = @import("std");

pub const entropy = @import("entropy.zig");
pub const stats = @import("stats.zig");
pub const intervals = @import("intervals.zig");
pub const matrix = @import("matrix.zig");

pub const shannonEntropy = entropy.shannonEntropy;
pub const shannonEntropyNonZero = entropy.shannonEntropyNonZero;
pub const isAllZero = stats.isAllZero;
pub const EntropyAccumulator = entropy.EntropyAccumulator;

pub const ByteHistogram = stats.ByteHistogram;
pub const ByteStats = stats.ByteStats;
pub const computeByteHistogram = stats.computeByteHistogram;
pub const computeByteStats = stats.computeByteStats;

pub const Interval = intervals.Interval;
pub const hasOverlapInSorted = intervals.hasOverlapInSorted;
pub const sortAndCheckOverlap = intervals.sortAndCheckOverlap;
pub const computeComplementGaps = intervals.computeComplementGaps;

pub const Mat3 = matrix.Mat3;
pub const fixed16_16ToFloat = matrix.fixed16_16ToFloat;
pub const fixed2_30ToFloat = matrix.fixed2_30ToFloat;
