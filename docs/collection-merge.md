# Collection merges

Run `prefablens setup-merge` once in each clone.
Then use `git merge`.
The native Git strategy checks collection changes and their Prefab sources.
It also checks affected Variants when Git reports no content conflict for those files.

## Arrays and lists

PrefabLens compares each side with the common base.
It combines independent insertions, removals, and item edits.
It preserves repeated elements and does not use a field name as an element identity.

| Base | Ours | Theirs | Result |
| --- | --- | --- | --- |
| `[1, 2, 3]` | `[2, 3]` | `[1, 20, 3]` | `[20, 3]` |
| `[1, 2, 3]` | `[1]` | `[1, 2, 30]` | Choose whether to retain `30`. The result keeps `2` removed. |

When both sides insert into the same gap, the UI offers two orders:

- **F1 Ours + Theirs** puts the Ours block first.
- **F2 Theirs + Ours** puts the Theirs block first.

Each action previews the combined result.
Apply the result.
When all conflicts have a resolution, select **Complete**.
A local choice retains independent accepted changes elsewhere in the collection.

If repeated values or moves leave more than one possible correspondence, choose a local result.
The result editor accepts YAML values and checks their shape before acceptance.
Competing source formatting can require a choice for the complete collection.

Packed `int[]` values use the same collection rules.
PrefabLens preserves their integer values and serialized format.

## Dictionaries

Unity 6.6 serializes `Dictionary<TKey, TValue>` fields with `[SerializeField]`.
It stores key/value entries in insertion order.
See [Unity dictionary serialization](https://docs.unity3d.com/6000.6/Documentation/Manual/script-serialization-dictionaries.html).
PrefabLens uses committed script declarations to distinguish a dictionary from an array of key/value structs.

Typed merging currently supports `Dictionary<string, int>` and `Dictionary<int, string>` with default key equality.
Independent keys and value edits merge automatically.
The same added key with different values requires a choice.
A key removal that conflicts with a value edit also requires a choice.

The result must contain valid, unique keys for the supported type.
Empty strings and strings such as `null` remain valid string keys.
PrefabLens preserves serialized entry order.
Competing reorder changes require a choice.
Independent new keys use Ours order followed by Theirs order.

Other types, custom comparers, and unclear declarations require an explicit result.
Commit the relevant scripts and metadata so each input revision has its own type information.
PrefabLens does not use an unstaged script edit to reinterpret historical data.

## Prefab Variants

Variant overrides address array and dictionary entries by index.
PrefabLens reads the source graph for each input revision, including nested Variants.
It merges the effective collection, then writes overrides against the selected output source.
This keeps an edit attached to the corresponding element after an insertion or removal.

PrefabLens resolves source conflicts before dependent Variants.
Inherited values use the selected source.
They do not create new overrides to restore a source change that the source decision rejected.
Explicit overrides remain distinct from inherited values, even when their values are equal.
Inactive override rows cannot become active again through merged collection growth.
Unknown source data or item defaults require an explicit choice.

If a result converts inheritance into an override, a local choice shows the source and result values.
This includes changes that make an inherited collection length explicit.
The change stays unresolved until you select a result.

PrefabLens checks the result against the selected source before acceptance.
If the selected source changes while a file is open, PrefabLens rejects the stale result.
Reopen the file after the source decision is complete.

## Missing merge context

Without a unique common base, the native strategy offers explicit whole-file choices.
It preserves the actual branch versions.
Custom results must parse as Unity YAML.
Source inheritance remains unverified for these whole-file choices.

## Validation fixtures

The repository contains real Unity collection fixtures under `core/src/testdata/collections`.
Their runtime verifier loads resolved prefabs and checks array, dictionary, and Variant values.
The fixture README records the Editor versions and commands.
