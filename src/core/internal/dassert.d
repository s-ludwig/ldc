/*
Provides light-weight formatting utilities for pretty-printing
on assertion failures
*/
module core.internal.dassert;

/// Allows customized assert error messages
string _d_assert_fail(string comp, A, B)(auto ref const scope A a, auto ref const scope B b)
{
    /*
    The program will be terminated after the assertion error message has
    been printed and its not considered part of the "main" program.
    Also, catching an AssertError is Undefined Behavior
    Hence, we can fake purity and @nogc-ness here.
    */

    string valA = miniFormatFakeAttributes(a);
    string valB = miniFormatFakeAttributes(b);
    enum token = invertCompToken(comp);
    return combine(valA, token, valB);
}

/// Combines the supplied arguments into one string "valA token valB"
private string combine(const scope string valA, const scope string token,
const scope string valB) pure nothrow @nogc @safe
{
    const totalLen = valA.length + token.length + valB.length + 2;
    char[] buffer = cast(char[]) pureAlloc(totalLen)[0 .. totalLen];
    // @nogc-concat of "<valA> <comp> <valB>"
    auto n = valA.length;
    buffer[0 .. n] = valA;
    buffer[n++] = ' ';
    buffer[n .. n + token.length] = token;
    n += token.length;
    buffer[n++] = ' ';
    buffer[n .. n + valB.length] = valB;
    return (() @trusted => cast(string) buffer)();
}

// Yields the appropriate printf format token for a type T
// Indended to be used by miniFormat
private template getPrintfFormat(T)
{
    static if (is(T == long))
    {
        enum getPrintfFormat = "%lld";
    }
    else static if (is(T == ulong))
    {
        enum getPrintfFormat = "%llu";
    }
    else static if (__traits(isIntegral, T))
    {
        static if (__traits(isUnsigned, T))
        {
            enum getPrintfFormat = "%u";
        }
        else
        {
            enum getPrintfFormat = "%d";
        }
    }
    else
    {
        static assert(0, "Unknown format");
    }
}

/**
Minimalistic formatting for use in _d_assert_fail to keep the compilation
overhead small and avoid the use of Phobos.
*/
private string miniFormat(V)(const scope ref V v)
{
    import core.internal.traits: isAggregateType;
    import core.stdc.stdio : sprintf;
    import core.stdc.string : strlen;

    static if (is(V == shared T, T))
    {
        // Use atomics to avoid race conditions whenever possible
        static if (__traits(compiles, atomicLoad(v)))
        {
            T tmp = cast(T) atomicLoad(v);
            return miniFormat(tmp);
        }
        else
        {   // Fall back to a simple cast - we're violating the type system anyways
            return miniFormat(*cast(T*) &v);
        }
    }
    else static if (is(V == bool))
    {
        return v ? "true" : "false";
    }
    else static if (__traits(isIntegral, V))
    {
        enum printfFormat = getPrintfFormat!V;
        char[20] val;
        const len = sprintf(&val[0], printfFormat, v);
        return val.idup[0 .. len];
    }
    else static if (__traits(isFloating, V))
    {
        char[60] val;
        int len;
        static if (is(V == cfloat) || is(V == cdouble))
            len = sprintf(&val[0], "%g + %gi", v.re, v.im);
        else static if (is(V == creal))
            len = sprintf(&val[0], "%Lg + %Lgi", v.re, v.im);
        else static if (is(V == real) || is(V == ireal))
            len = sprintf(&val[0], "%Lg", v);
        else
            len = sprintf(&val[0], "%g", v);
        return val.idup[0 .. len];
    }
    // special-handling for void-arrays
    else static if (is(V == typeof(null)))
    {
        return "`null`";
    }
    // toString() isn't always const, e.g. classes inheriting from Object
    else static if (__traits(compiles, { string s = V.init.toString(); }))
    {
        // Object references / struct pointers may be null
        static if (is(V == class) || is(V == interface) || is(V == U*, U))
        {
            if (v is null)
                return "`null`";
        }

        // Prefer const overload of toString
        static if (__traits(compiles, { string s = v.toString(); }))
            return v.toString();
        else
            return (cast() v).toString();
    }
    // Static arrays or slices (but not aggregates with `alias this`)
    else static if (is(V : U[], U) && !isAggregateType!V)
    {
        import core.internal.traits: Unqual;
        alias E = Unqual!U;

        // special-handling for void-arrays
        static if (is(E == void))
        {
            const bytes = cast(byte[]) v;
            return miniFormat(bytes);
        }
        // anything string-like
        else static if (is(E == char) || is(E == dchar) || is(E == wchar))
        {
            const s = `"` ~ v ~ `"`;

            // v could be a char[], dchar[] or wchar[]
            static if (is(typeof(s) : const char[]))
                return cast(immutable) s;
            else
            {
                import core.internal.utf: toUTF8;
                return toUTF8(s);
            }
        }
        else
        {
            string msg = "[";
            foreach (i, ref el; v)
            {
                if (i > 0)
                    msg ~= ", ";

                // don't fully print big arrays
                if (i >= 30)
                {
                    msg ~= "...";
                    break;
                }
                msg ~= miniFormat(el);
            }
            msg ~= "]";
            return msg;
        }
    }
    else static if (is(V : Val[K], K, Val))
    {
        size_t i;
        string msg = "[";
        foreach (k, ref val; v)
        {
            if (i > 0)
                msg ~= ", ";
            // don't fully print big AAs
            if (i++ >= 30)
            {
                msg ~= "...";
                break;
            }
            msg ~= miniFormat(k) ~ ": " ~ miniFormat(val);
        }
        msg ~= "]";
        return msg;
    }
    else static if (is(V == struct))
    {
        string msg = V.stringof ~ "(";
        foreach (i, ref field; v.tupleof)
        {
            if (i > 0)
                msg ~= ", ";
            msg ~= miniFormat(field);
        }
        msg ~= ")";
        return msg;
    }
    else
    {
        return V.stringof;
    }
}

// This should be a local import in miniFormat but fails with a cyclic dependency error
// core.thread.osthread -> core.time -> object -> core.internal.array.capacity
// -> core.atomic -> core.thread -> core.thread.osthread
import core.atomic : atomicLoad;

// Inverts a comparison token for use in _d_assert_fail
private string invertCompToken(string comp)
{
    switch (comp)
    {
        case "==":
            return "!=";
        case "!=":
            return "==";
        case "<":
            return ">=";
        case "<=":
            return ">";
        case ">":
            return "<=";
        case ">=":
            return "<";
        case "is":
            return "!is";
        case "!is":
            return "is";
        case "in":
            return "!in";
        case "!in":
            return "in";
        default:
            assert(0, "Invalid comparison operator: " ~ comp);
    }
}

private auto assumeFakeAttributes(T)(T t) @trusted
{
    import core.internal.traits : Parameters, ReturnType;
    alias RT = ReturnType!T;
    alias P = Parameters!T;
    alias type = RT function(P) nothrow @nogc @safe pure;
    return cast(type) t;
}

private string miniFormatFakeAttributes(T)(const scope ref T t)
{
    alias miniT = miniFormat!T;
    return assumeFakeAttributes(&miniT)(t);
}

private auto pureAlloc(size_t t)
{
    static auto alloc(size_t len)
    {
        return new ubyte[len];
    }
    return assumeFakeAttributes(&alloc)(t);
}
