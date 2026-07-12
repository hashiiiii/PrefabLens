using System;
using System.Collections.Generic;
using UnityEngine;

// Custom ScriptableObject exercising the .asset diff surface: scalars, strings,
// arrays, nested serializable classes, and object references.
[CreateAssetMenu(fileName = "FixtureData", menuName = "Fixtures/FixtureData")]
public class FixtureData : ScriptableObject
{
    [Serializable]
    public class Item
    {
        public string itemName;
        public int cost;
        public bool consumable;
    }

    public int hitPoints;
    public string title;
    public float[] weights;
    public List<Item> items = new List<Item>();
    public Material materialRef;
    public Color tint = Color.white;
}
