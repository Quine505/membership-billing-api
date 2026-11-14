// round(a × b / c), half up, on whole minor units.
// (2ab + c) / 2c equals ab/c + 1/2, and BigInt division drops the fraction. No floats are involved.
export function mulDivRound(a: number, b: number, c: number): number {
  return Number((2n * BigInt(a) * BigInt(b) + BigInt(c)) / (2n * BigInt(c)))
}
