# Collection merges

Run `prefablens setup-merge` once in each clone.
Then use `git merge`.
The native Git strategy checks array changes in UnityYAML files.

## Arrays and lists

PrefabLens compares each side with the common base.
It combines independent insertions, removals, and item edits.
It preserves repeated elements and does not use a field name as an element identity.

| Base | Ours | Theirs | Result |
| --- | --- | --- | --- |
| `[1, 2, 3]` | `[2, 3]` | `[1, 20, 3]` | `[20, 3]` |
| `[1, 2, 3]` | `[1]` | `[1, 2, 30]` | Choose whether to retain `30`. The result keeps `2` removed. |

When both sides insert into the same gap, the field heading offers **One side** and **Both sides** modes.
Press **Shift+T** (shown as `⇧T`) from either pane to switch modes.
You can also click the current mode.
**One side** shows the original choices. **Both sides** offers:

- **Ours** becomes **Ours + Theirs**, with the Ours block first.
- **Theirs** becomes **Theirs + Ours**, with the Theirs block first.

Release **Shift**, choose an order with the arrow keys, and press **Enter** to apply it.
**Result** shows both blocks in that order, such as `[Ours, Theirs]`.
Press **Shift+T** again to restore the original side choices.
Toggling changes the choices without changing **Result**.
Applying a result or moving to another conflict returns to **One side**.

The mode control appears only when the conflict supports both insertion orders.
Scalar fields and array delete/edit conflicts do not show the control.
**Shift+T** changes the mode until you start editing **Result**.
While editing, it inserts text.

To preview a choice before applying it, click its value.
Click **Result**, or focus it and press **Enter**, to edit the preview.
The existing text stays in place; press **Enter** to apply it.
See [Edit Result](cli.md#edit-result) for multiline editing and paste controls.
When all conflicts have a resolution, select **Complete**.
A local choice retains independent accepted changes elsewhere in the collection.

If repeated values or moves leave more than one possible correspondence, choose a local result.
The result editor accepts YAML values and checks their shape before acceptance.
Competing source formatting can require a choice for the complete collection.

Packed `int[]` values use the same collection rules.
PrefabLens preserves their integer values and serialized format.

## Dictionaries

PrefabLens merges these YAML shapes by key, not by list position:

- Pair sequences `{ key, value }` or `{ first, second }`
- Parallel `SerializedDictionary` maps with `m_Keys` and `m_Values` of equal length

Independent key insertions and removals combine.
The same key with different values is an edit/edit conflict.
A delete on one side and an edit on the other is a delete/edit conflict.
Nested lists stay ordered. Nested dictionaries stay keyed.

If only one side reorders shared keys, that side's order is kept.
If both sides reorder shared keys differently, the field is an insertion-order conflict.
Dictionaries do not offer **Both sides** mode.
New keys land after the preceding shared key; extras already on the order-keeping side stay before extras from the other side.

A C# schema of `Dictionary<,>` or `SerializedDictionary<,>` selects this path.
Without a schema, the YAML shape is enough.
A schema that marks a pair sequence `.ordered` still uses list merge.

Unknown or malformed dictionary YAML, duplicate keys, and `m_Keys`/`m_Values` length mismatch stay a whole-collection conflict.

Diff hides a pure reorder.
Paths use the key, such as `Stats[Goblin]` or `Stats[Goblin].Hp`.

## Prefab Variant collections

When a source prefab is available, PrefabLens instantiates both sides of a modified Prefab Variant before display.
`Array.size` runs first so later `Array.data[i]` rows can resolve.
The diff then shows resolved item paths such as `Items[2].Speed` instead of the raw modification rows.

Value-only `Array.data[i]` property overrides merge like other Prefab modifications, keyed by `target` and `propertyPath`.
`Array.size` changes stay unsupported: a resize can retarget later indices, and PrefabLens does not yet re-encode resolved collections back into `m_Modifications`.
Without the source prefab, collection overrides stay as modification rows.

## Unsupported collection shapes

Odin dictionaries and other unrecognized keyed shapes stay a whole-collection conflict.
Use an explicit result for the whole collection or file when such a change needs resolution.

## Missing merge context

Without a unique common base, the native strategy offers explicit whole-file choices.
It preserves the actual branch versions.
Custom results must parse as Unity YAML.

## Validation fixtures

The repository contains real Unity collection fixtures under `core/src/testdata/collections`.
Their runtime verifier loads resolved prefabs and checks ordered array and packed `int[]` values.
The fixture README records the Editor versions and commands.
