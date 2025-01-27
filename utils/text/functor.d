/**
 * Functor-powered lazy @nogc text formatting.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.text.functor;

import std.format : formattedWrite, formatValue, FormatSpec;
import std.functional : forward;
import std.range.primitives : isOutputRange;

import ae.utils.functor.composition : isFunctor, select, seq;
import ae.utils.functor.primitives : functor;
import ae.utils.meta : tupleMap, I;

/// Given zero or more values, returns a functor which retains a copy of these values;
/// the functor can later be called with a sink, which will make it write the values out.
/// The returned functor's signature varies depending on whether a
/// format string is specified, but either way compatible with
/// `toString` signatures accepted by `formattedWrite`
/// If a format string is specified, that will be used to format the values;
/// otherwise, a format string will be accepted at call time.
/// For details, see accepted `toString` signatures in the
/// "Structs, Unions, Classes, and Interfaces" section of
/// https://dlang.org/phobos/std_format_write.html.
template formattingFunctor(
	string fmt = null,
	int line = __LINE__, // https://issues.dlang.org/show_bug.cgi?id=23904
	T...)
{
	static if (fmt)
		alias fun =
			(T values, ref w)
			{
				w.formattedWrite!fmt(values);
			};
	else
		alias fun =
			(T values, ref w, const ref fmt)
			{
				foreach (ref value; values)
					w.formatValue(value, fmt);
			};

	auto formattingFunctor(auto ref T values)
	{
		return functor!fun(forward!values);
	}
}

///
unittest
{
	import std.array : appender;
	import std.format : singleSpec;

	auto a = appender!string;
	auto spec = "%03d".singleSpec;
	formattingFunctor(5)(a, spec);
	assert(a.data == "005");
}

///
unittest
{
	import std.array : appender;
	auto a = appender!string;
	formattingFunctor!"%03d"(5)(a); // or `&a.put!(const(char)[])`
	assert(a.data == "005");
}

/// Constructs a stringifiable object from a functor.
auto stringifiable(F)(F functor)
if (isFunctor!F)
{
	// std.format uses speculative compilation to detect compatibility.
	// As such, any error in the function will just cause the
	// object to be silently stringified as "Stringifiable(Functor(...))".
	// To avoid that, try an explicit instantiation here to
	// get detailed information about any errors in the function.
	debug if (false)
	{
		// Because std.format accepts any one of several signatures,
		// try all valid combinations to first check that at least one
		// is accepted.
		FormatSpec!char fc;
		FormatSpec!wchar fw;
		FormatSpec!dchar fd;
		struct DummyWriter(Char) { void put(Char c) {} }
		DummyWriter!char wc;
		DummyWriter!wchar ww;
		DummyWriter!dchar wd;
		void dummySink(const(char)[]) {}
		static if(
			!is(typeof(functor(wc, fc))) &&
			!is(typeof(functor(ww, fw))) &&
			!is(typeof(functor(wd, fd))) &&
			!is(typeof(functor(wc))) &&
			!is(typeof(functor(ww))) &&
			!is(typeof(functor(wd))) &&
			!is(typeof(functor(&dummySink))))
		{
			// None were valid; try non-speculatively with the simplest one:
			pragma(msg, "Functor ", F.stringof, " does not successfully instantiate with any toString signatures.");
			pragma(msg, "Attempting to non-speculatively instantiate with delegate sink:");
			functor(&dummySink);
		}
	}

	static struct Stringifiable
	{
		F functor;

		void toString(this This, Writer, Char)(ref Writer writer, const ref FormatSpec!Char fmt)
		if (isOutputRange!(Writer, Char))
		{
			functor(writer, fmt);
		}

		void toString(this This, Writer)(ref Writer writer)
		{
			functor(writer);
		}

		void toString(this This)(scope void delegate(const(char)[]) sink)
		{
			functor(sink);
		}
	}
	return Stringifiable(functor);
}

///
unittest
{
	import std.conv : text;
	auto f = (void delegate(const(char)[]) sink) => sink("Hello");
	assert(stringifiable(f).text == "Hello", stringifiable(f).text);
}

/// Constructs a stringifiable object from a value
/// (i.e., a lazily formatted object).
/// Combines `formattingFunctor` and `stringifiable`.
auto formatted(string fmt = null, T...)(auto ref T values)
{
	return values
		.formattingFunctor!fmt()
		.stringifiable;
}

///
unittest
{
	import std.conv : text;
	import std.format : format;
	assert(formatted(5).text == "5");
	assert(formatted!"%03d"(5).text == "005");
	assert(format!"%s%s%s"("<", formatted!"%x"(64), ">") == "<40>");
	assert(format!"<%03d>"(formatted(5)) == "<005>");
}

/// Constructs a functor type from a function alias, and wraps it into
/// a stringifiable object.  Can be used to create stringifiable
/// widgets which need a sink for more complex behavior.
template stringifiable(alias fun, T...)
{
	auto stringifiable()(auto ref T values)
	{
		return values
			.functor!fun()
			.I!(.stringifiable);
	}
}

///
unittest
{
	alias humanSize = stringifiable!(
		(size, sink)
		{
			import std.format : formattedWrite;
			if (!size)
				// You would otherwise need to wrap everything in fmtIf:
				return sink("0");
			static immutable prefixChars = " KMGTPEZY";
			size_t power = 0;
			while (size > 1000 && power + 1 < prefixChars.length)
				size /= 1024, power++;
			sink.formattedWrite!"%s %sB"(size, prefixChars[power]);
		}, real);

	import std.conv : text;
	assert(humanSize(0).text == "0");
	assert(humanSize(8192).text == "8 KB");
}

/// Returns an object which, depending on a condition, is stringified
/// as one of two objects.
/// The two branches should themselves be passed as nullary functors,
/// to enable lazy evaluation.
/// Combines `formattingFunctor`, `stringifiable`, and `select`.
auto fmtIf(string fmt = null, Cond, T, F)(Cond cond, T t, F f) @nogc
if (isFunctor!T && isFunctor!F)
{
	// Store the value-returning functor into a new functor, which will accept a sink.
	// When the new functor is called, evaluate the value-returning functor,
	// put the value into a formatting functor, and immediately call it with the sink.

	// Must be explicitly static due to
	// https://issues.dlang.org/show_bug.cgi?id=23896 :
	static void fun(X, Sink...)(X x, auto ref Sink sink)
	{
		x().formattingFunctor!fmt()(forward!sink);
	}
	return select(
		cond,
		functor!fun(t),
		functor!fun(f),
	).stringifiable;
}

///
unittest
{
	import std.conv : text;
	assert(fmtIf(true , () => 5, () => "apple").text == "5");
	assert(fmtIf(false, () => 5, () => "apple").text == "apple");

	// Scope lazy when? https://issues.dlang.org/show_bug.cgi?id=12647
	auto division(int a, int b) { return fmtIf(b != 0, () => a / b, () => "NaN"); }
	assert(division(4, 2).text == "2");
	assert(division(4, 0).text == "NaN");
}

/// Returns an object which is stringified as all of the given objects
/// in sequence.  In essence, a lazy `std.conv.text`.
/// Combines `formattingFunctor`, `stringifiable`, and `seq`.
auto fmtSeq(string fmt = "%s", Values...)(Values values) @nogc
{
	return
		values
		.tupleMap!((ref value) => formattingFunctor!fmt(value)).expand
		.seq
		.stringifiable;
}

unittest
{
	import std.conv : text;
	assert(fmtSeq(5, " ", "apple").text == "5 apple");
}

