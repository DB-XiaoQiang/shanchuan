namespace Shanchuan.Core;

public sealed record TransferProgressValues(long UploadedBytes, long TotalBytes, double Fraction);

/// <summary>Combines real per-file upload callbacks using byte weighting, including the control file.</summary>
public sealed class TransferByteProgress
{
    private readonly object _sync = new();
    private readonly long[] _fileSizes;
    private readonly double[] _fileFractions;
    private readonly double _weightedTotalBytes;

    public TransferByteProgress(IEnumerable<long> fileSizes)
    {
        _fileSizes = fileSizes.Select(size => Math.Max(0, size)).ToArray();
        _fileFractions = new double[_fileSizes.Length];
        _weightedTotalBytes = _fileSizes.Sum(size => (double)size);
        TotalBytes = _fileSizes.Aggregate(0L, (sum, size) =>
            long.MaxValue - sum < size ? long.MaxValue : sum + size);
    }

    public long TotalBytes { get; }

    public TransferProgressValues Update(int fileIndex, double fraction)
    {
        lock (_sync)
        {
            if (fileIndex >= 0 && fileIndex < _fileFractions.Length && double.IsFinite(fraction))
                _fileFractions[fileIndex] = Math.Max(_fileFractions[fileIndex], Math.Clamp(fraction, 0, 1));

            if (_weightedTotalBytes <= 0)
            {
                var completed = _fileFractions.Length > 0 && _fileFractions.All(value => value == 1);
                return new TransferProgressValues(0, 0, completed ? 1 : 0);
            }

            var uploaded = _fileSizes.Zip(_fileFractions, (size, value) => (double)size * value).Sum();
            var allBytesCompleted = _fileSizes.Zip(_fileFractions, (size, value) => size == 0 || value == 1).All(value => value);
            var combined = allBytesCompleted ? 1 : Math.Min(Math.BitDecrement(1), Math.Max(0, uploaded / _weightedTotalBytes));
            var uploadedBytes = combined == 1 ? TotalBytes : uploaded >= long.MaxValue ? long.MaxValue : Math.Min(TotalBytes, (long)uploaded);
            return new TransferProgressValues(uploadedBytes, TotalBytes, combined);
        }
    }
}
