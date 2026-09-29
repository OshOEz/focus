import Foundation

/// Solves A·X = B by Gaussian elimination with partial pivoting.
/// `a` is n×n row-major, `b` is n×m row-major. Returns X (n×m row-major), or nil if singular.
func solveLinear(_ a: [Double], _ b: [Double], n: Int, m: Int) -> [Double]? {
    var a = a, b = b
    for col in 0..<n {
        var pivot = col
        for r in (col + 1)..<n where abs(a[r * n + col]) > abs(a[pivot * n + col]) { pivot = r }
        guard abs(a[pivot * n + col]) > 1e-12 else { return nil }
        if pivot != col {
            for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
            for k in 0..<m { b.swapAt(col * m + k, pivot * m + k) }
        }
        for r in (col + 1)..<n {
            let f = a[r * n + col] / a[col * n + col]
            if f == 0 { continue }
            for k in col..<n { a[r * n + k] -= f * a[col * n + k] }
            for k in 0..<m { b[r * m + k] -= f * b[col * m + k] }
        }
    }
    var x = [Double](repeating: 0, count: n * m)
    for r in stride(from: n - 1, through: 0, by: -1) {
        for k in 0..<m {
            var s = b[r * m + k]
            for c in (r + 1)..<n { s -= a[r * n + c] * x[c * m + k] }
            x[r * m + k] = s / a[r * n + r]
        }
    }
    return x
}
