using UnityEngine;

// MonoBehaviour placed on fixture prefabs so their YAML contains a MonoBehaviour
// document with a script fileID reference plus assorted serialized fields.
public class FixtureBehaviour : MonoBehaviour
{
    public float speed = 1.5f;
    public int level = 1;
    public string label = "default";
    public Vector3 offset = Vector3.zero;
    public GameObject target;
}
