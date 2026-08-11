const BEFORE_PREFAB_TEXT = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5
`;

export const BEFORE_PREFAB = new TextEncoder().encode(BEFORE_PREFAB_TEXT);
export const AFTER_PREFAB = new TextEncoder().encode(BEFORE_PREFAB_TEXT.replace("0.5", "0.8"));
export const BINARY_ASSET = Uint8Array.from([0, 1, 2, 3]);
