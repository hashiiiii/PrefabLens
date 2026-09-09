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
Focus **Ours** or **Theirs**, then press **Shift + T** (shown as `⇧T`) to switch modes.
You can also click the current mode.
**One side** shows the original choices. **Both sides** offers:

- **Ours** becomes **Ours + Theirs**, with the Ours block first.
- **Theirs** becomes **Theirs + Ours**, with the Theirs block first.

Release **Shift**, choose an order with the arrow keys, and press **Enter** to apply it.
**Result** shows both blocks in that order, such as `[Ours, Theirs]`.
Press **Shift + T** again to restore the original side choices.
Toggling changes the choices without changing **Result**.
Applying a result or moving to another conflict returns to **One side**.

The mode control appears only when the conflict supports both insertion orders.
Scalar fields and array delete/edit conflicts do not show the control.
Letters enter text when **Result** has focus.

To preview a choice before applying it, click its value.
Click **Result** or press **Ctrl+E** to edit the preview.
The existing text stays in place; press **Enter** to apply it.
See [Edit Result](cli.md#edit-result) for multiline editing and paste controls.
When all conflicts have a resolution, select **Complete**.
A local choice retains independent accepted changes elsewhere in the collection.

If repeated values or moves leave more than one possible correspondence, choose a local result.
The result editor accepts YAML values and checks their shape before acceptance.
Competing source formatting can require a choice for the complete collection.

Packed `int[]` values use the same collection rules.
PrefabLens preserves their integer values and serialized format.

## Unsupported collection shapes

PrefabLens does not merge dictionary fields or collection overrides in Prefab Variants.
Use an explicit result for the whole collection or file when such a change needs resolution.

## Missing merge context

Without a unique common base, the native strategy offers explicit whole-file choices.
It preserves the actual branch versions.
Custom results must parse as Unity YAML.

## Validation fixtures

The repository contains real Unity collection fixtures under `core/src/testdata/collections`.
Their runtime verifier loads resolved prefabs and checks ordered array and packed `int[]` values.
The fixture README records the Editor versions and commands.
