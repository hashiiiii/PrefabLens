using System;
using UnityEngine;

public class AuditBehaviour : MonoBehaviour
{
    [Serializable]
    public class Item
    {
        public string name;
        public int power = 1;
        public int speed = 1;
    }

    public Item[] items = Array.Empty<Item>();
    public string[] names = Array.Empty<string>();
    public int[] numbers = Array.Empty<int>();
    public int left = 1;
    public int right = 1;
}
