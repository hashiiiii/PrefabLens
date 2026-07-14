// Minimal Unity API stand-ins so editor/Editor compiles on the plain dotnet SDK.
// Signatures mirror Unity 2022.3; bodies are inert. The tests only exercise
// Unity-free code paths, so none of these members run during `dotnet test`.
using System;

namespace UnityEngine
{
    public class Object { }

    [AttributeUsage(AttributeTargets.Field)]
    public sealed class SerializeField : Attribute { }

    public struct Color
    {
        public float r,
            g,
            b,
            a;

        public Color(float r, float g, float b, float a = 1f)
        {
            this.r = r;
            this.g = g;
            this.b = b;
            this.a = a;
        }
    }

    public enum TextAnchor
    {
        UpperLeft,
        UpperCenter,
        UpperRight,
        MiddleLeft,
        MiddleCenter,
        MiddleRight,
        LowerLeft,
        LowerCenter,
        LowerRight,
    }
}
