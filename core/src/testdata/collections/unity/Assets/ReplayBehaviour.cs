using System;
using UnityEngine;

public class ReplayBehaviour : MonoBehaviour
{
    [Serializable]
    public class Item
    {
        public string name;
        public int speed = 1;
        [HideInInspector] public int hidden = 37;
    }
    public Item[] items = Array.Empty<Item>();
}
