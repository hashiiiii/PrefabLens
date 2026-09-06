# Sparse override replay

Unity 6000.7.0a2 generated the source prefab, script metadata, and Variant row templates.
The fixture cases apply those templates with an omitted `hidden` member and explicit `name` and `speed` rows.
Remove and shrink cases retain inactive rows, as Unity can do after a collection shrinks.

`ReplayBehaviour.Item.hidden` has a C# initializer of 37. Loading an omitted override over this empty source produced 0.
The merge must preserve the omitted member rather than derive a value from that initializer.
The real Editor probe compared each replay result with the observed baseline value.
