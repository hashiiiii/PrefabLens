const BEFORE_PREFAB_TEXT = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5
`;

export const BEFORE_PREFAB = new TextEncoder().encode(BEFORE_PREFAB_TEXT);
export const AFTER_PREFAB = new TextEncoder().encode(BEFORE_PREFAB_TEXT.replace("0.5", "0.8"));
export const BINARY_ASSET = Uint8Array.from([0, 1, 2, 3]);

export const VARIANT_PREFAB = new TextEncoder().encode(`--- !u!1001 &1001
PrefabInstance:
  m_Modification:
    m_Modifications:
    - target: {fileID: 40, guid: src0, type: 3}
      propertyPath: m_LocalScale.y
      value: 2
  m_SourcePrefab: {fileID: 100100000, guid: src0, type: 3}`);

export const SOURCE_PREFAB = new TextEncoder().encode(`--- !u!1 &10
GameObject:
  m_Name: Source
  m_Component:
  - component: {fileID: 40}
--- !u!4 &40
Transform:
  m_GameObject: {fileID: 10}
  m_LocalScale: {x: 1, y: 1, z: 1}`);
