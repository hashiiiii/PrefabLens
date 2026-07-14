using System;
using System.Collections.Generic;
using PrefabLens.MiniJson;

namespace PrefabLens
{
    public sealed class BulkEntry
    {
        public string Path;
        public DiffModel Diff;
    }

    /// Reader-side model for the CLI's bulk mode (`prefablens --json` with no operands):
    /// a top-level array of {path, diff} for every changed UnityYAML file vs HEAD.
    /// Entries missing either key are skipped rather than failing (same tolerance as DiffModel).
    public sealed class BulkModel
    {
        public List<BulkEntry> Entries = new();

        public static BulkModel Parse(string json)
        {
            if (Json.Deserialize(json) is not List<object> arr)
                throw new FormatException("bulk json root is not an array");
            var m = new BulkModel();
            foreach (var item in arr)
            {
                if (item is not Dictionary<string, object> o)
                    continue;
                if (
                    o.TryGetValue("path", out var p)
                    && p is string path
                    && o.TryGetValue("diff", out var d)
                    && d is Dictionary<string, object> diff
                )
                    m.Entries.Add(new BulkEntry { Path = path, Diff = DiffModel.FromDict(diff) });
            }
            return m;
        }

        /// The list badge for an entry: a wholly added / wholly removed asset keeps its
        /// status, anything else (including an empty semantic diff) reads as modified.
        public static DiffStatus AggregateStatus(DiffModel diff)
        {
            var any = false;
            var allAdded = true;
            var allRemoved = true;
            foreach (var n in diff.Roots)
            {
                any = true;
                allAdded &= n.Status == DiffStatus.Added;
                allRemoved &= n.Status == DiffStatus.Removed;
            }
            foreach (var c in diff.Loose)
            {
                any = true;
                allAdded &= c.Status == DiffStatus.Added;
                allRemoved &= c.Status == DiffStatus.Removed;
            }
            if (!any)
                return DiffStatus.Modified;
            if (allAdded)
                return DiffStatus.Added;
            if (allRemoved)
                return DiffStatus.Removed;
            return DiffStatus.Modified;
        }
    }
}
