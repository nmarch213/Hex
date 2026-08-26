/** Converts a monotonic nanosecond interval into a safe whole-millisecond duration. */
export const elapsedMilliseconds = (
  startedAt: bigint,
  finishedAt: bigint
): number =>
  Math.max(0, Math.round(Number(finishedAt - startedAt) / 1_000_000))
