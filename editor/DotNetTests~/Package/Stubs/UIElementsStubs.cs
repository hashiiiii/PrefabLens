// Minimal Unity API stand-ins so editor/Editor compiles on the plain dotnet SDK.
// Signatures mirror Unity 2022.3; bodies are inert.
#pragma warning disable 67 // stub events are never raised
using System;
using System.Collections;
using System.Collections.Generic;

namespace UnityEngine.UIElements
{
    public enum FlexDirection
    {
        Column,
        ColumnReverse,
        Row,
        RowReverse,
    }

    public enum Align
    {
        Auto,
        FlexStart,
        Center,
        FlexEnd,
        Stretch,
    }

    public enum WhiteSpace
    {
        Normal,
        NoWrap,
    }

    public struct StyleFloat
    {
        public static implicit operator StyleFloat(float v) => default;
    }

    public struct StyleLength
    {
        public static implicit operator StyleLength(float v) => default;
    }

    public struct StyleColor
    {
        public static implicit operator StyleColor(Color v) => default;
    }

    public struct StyleEnum<T>
        where T : struct, IConvertible
    {
        public static implicit operator StyleEnum<T>(T v) => default;
    }

    public interface IStyle
    {
        StyleEnum<FlexDirection> flexDirection { get; set; }
        StyleLength marginTop { get; set; }
        StyleLength marginBottom { get; set; }
        StyleLength marginLeft { get; set; }
        StyleLength marginRight { get; set; }
        StyleLength paddingLeft { get; set; }
        StyleLength paddingRight { get; set; }
        StyleFloat flexGrow { get; set; }
        StyleEnum<TextAnchor> unityTextAlign { get; set; }
        StyleEnum<Align> alignSelf { get; set; }
        StyleEnum<Align> alignItems { get; set; }
        StyleEnum<WhiteSpace> whiteSpace { get; set; }
        StyleColor color { get; set; }
    }

    sealed class Style : IStyle
    {
        public StyleEnum<FlexDirection> flexDirection { get; set; }
        public StyleLength marginTop { get; set; }
        public StyleLength marginBottom { get; set; }
        public StyleLength marginLeft { get; set; }
        public StyleLength marginRight { get; set; }
        public StyleLength paddingLeft { get; set; }
        public StyleLength paddingRight { get; set; }
        public StyleFloat flexGrow { get; set; }
        public StyleEnum<TextAnchor> unityTextAlign { get; set; }
        public StyleEnum<Align> alignSelf { get; set; }
        public StyleEnum<Align> alignItems { get; set; }
        public StyleEnum<WhiteSpace> whiteSpace { get; set; }
        public StyleColor color { get; set; }
    }

    public class VisualElement
    {
        public IStyle style { get; } = new Style();

        public void Add(VisualElement child) { }

        public void Clear() { }
    }

    public class Label : VisualElement
    {
        public Label() { }

        public Label(string text)
        {
            this.text = text;
        }

        public string text { get; set; }
    }

    public class Button : VisualElement
    {
        public Button(Action clickEvent) { }

        public string text { get; set; }
    }

    public struct TreeViewItemData<T>
    {
        public TreeViewItemData(int id, T data, List<TreeViewItemData<T>> children = null) { }
    }

    public class TreeView : VisualElement
    {
        public float fixedItemHeight { get; set; }
        public Func<VisualElement> makeItem { get; set; }
        public Action<VisualElement, int> bindItem { get; set; }

        public void SetRootItems<T>(IList<TreeViewItemData<T>> rootItems) { }

        public T GetItemDataForIndex<T>(int index) => default;

        public void ExpandAll() { }
    }

    public enum TwoPaneSplitViewOrientation
    {
        Horizontal,
        Vertical,
    }

    public class TwoPaneSplitView : VisualElement
    {
        public TwoPaneSplitView(
            int fixedPaneIndex,
            float fixedPaneStartDimension,
            TwoPaneSplitViewOrientation orientation
        ) { }
    }

    public class ListView : VisualElement
    {
        public float fixedItemHeight { get; set; }
        public Func<VisualElement> makeItem { get; set; }
        public Action<VisualElement, int> bindItem { get; set; }
        public IList itemsSource { get; set; }

        public event Action<IEnumerable<object>> selectionChanged;

        public void SetSelection(int index) { }

        public void RefreshItems() { }
    }
}
