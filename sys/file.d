/**
 * File stuff
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.file;

import std.file, std.path, std.string, std.utf;
import std.array;

// ************************************************************************

version(Windows)
{
	string[] fastListDir(bool recursive = false, bool symlinks=false)(string pathname)
	{
		import std.c.windows.windows;

		string[] result;
		string c;
		HANDLE h;

		c = std.path.join(pathname, "*.*");
		WIN32_FIND_DATAW fileinfo;

		h = FindFirstFileW(toUTF16z(c), &fileinfo);
		if (h != INVALID_HANDLE_VALUE)
		{
			scope(exit) FindClose(h);

			do
			{
				// Skip "." and ".."
				if (std.string.wcscmp(fileinfo.cFileName.ptr, ".") == 0 ||
					std.string.wcscmp(fileinfo.cFileName.ptr, "..") == 0)
					continue;

				static if (!symlinks)
				{
					if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
						continue;
				}

				size_t clength = std.string.wcslen(fileinfo.cFileName.ptr);
				string name = std.utf.toUTF8(fileinfo.cFileName[0 .. clength]);
				string path = std.path.join(pathname, name);

				static if (recursive)
				{
					if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
					{
						result ~= fastListDir!recursive(path);
						continue;
					}
				}

				result ~= path;
			} while (FindNextFileW(h,&fileinfo) != FALSE);
		}
		return result;
	}
}
else
version (linux)
{
	// TODO: fixme
	private import std.c.stdlib : getErrno;
	private import std.c.linux.linux : DIR, dirent, opendir, readdir, closedir;

	string[] fastListDir(bool recursive=false)(string pathname)
	{
		static assert(recursive==false, "TODO");

		string[] result;
		DIR* h;
		dirent* fdata;

		h = opendir(toStringz(pathname));
		if (h)
		{
			try
			{
				while((fdata = readdir(h)) != null)
				{
					// Skip "." and ".."
					if (!std.c.string.strcmp(fdata.d_name.ptr, ".") ||
						!std.c.string.strcmp(fdata.d_name.ptr, ".."))
							continue;

					size_t len = std.c.string.strlen(fdata.d_name.ptr);
					result ~= fdata.d_name[0 .. len].dup;
				}
			}
			finally
			{
				closedir(h);
			}
		}
		else
		{
			throw new std.file.FileException(pathname, getErrno());
		}
		return result;
	}
}
else
	static assert(0, "TODO");

import std.datetime;
import std.exception;

// Will be made redundant by:
// https://github.com/D-Programming-Language/phobos/pull/513
// https://github.com/D-Programming-Language/phobos/pull/518
SysTime getMTime(string name)
{
	version(Windows)
	{
/*
		import std.c.windows.windows;

		auto h = CreateFileW(toUTF16z(name), FILE_READ_ATTRIBUTES, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		enforce(h!=INVALID_HANDLE_VALUE, "CreateFile");
		scope(exit) CloseHandle(h);
		FILETIME ft;
		enforce(GetFileTime(h, null, null, &ft), "GetFileTime");
		return FILETIMEToSysTime(&ft);
*/
		import stdwin = std.c.windows.windows;
		import win32.winnt;
		import win32.winbase;

		WIN32_FILE_ATTRIBUTE_DATA fad;
		enforce(GetFileAttributesExW(toUTF16z(name), GET_FILEEX_INFO_LEVELS .GetFileExInfoStandard, &fad), new FileException(name));
		return FILETIMEToSysTime(cast(stdwin.FILETIME*)&fad.ftLastWriteTime);
	}
	else
	{
		d_time ftc, fta, ftm;
		std.file.getTimes(name, ftc, fta, ftm);
		return ftm;
	}
}

void forceDelete(string fn)
{
	version(Windows)
	{
		import win32.winnt;
		import win32.winbase;

		auto fnW = toUTF16z(fn);
		auto attr = GetFileAttributesW(fnW);
		enforce(attr != INVALID_FILE_ATTRIBUTES, "GetFileAttributesW error");
		if (attr & FILE_ATTRIBUTE_READONLY)
			SetFileAttributesW(fnW, attr & ~FILE_ATTRIBUTE_READONLY);
	}

	remove(fn);
}

version (Windows)
{
	/// Return a file's unique ID.
	ulong getFileID(string fn)
	{
		import win32.winnt;
		import win32.winbase;

		auto fnW = toUTF16z(fn);
		auto h = CreateFileW(fnW, FILE_READ_ATTRIBUTES, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		enforce(h!=INVALID_HANDLE_VALUE, new FileException(fn));
		scope(exit) CloseHandle(h);
		BY_HANDLE_FILE_INFORMATION fi;
		enforce(GetFileInformationByHandle(h, &fi), "GetFileInformationByHandle");

		ULARGE_INTEGER li;
		li.LowPart  = fi.nFileIndexLow;
		li.HighPart = fi.nFileIndexHigh;
		auto result = li.QuadPart;
		enforce(result, "Null file ID");
		return result;
	}

	// TODO: return inode number on *nix
}

version(Windows)
{
	/// Find*File and CreateFile may fail in certain situations
	// Will be made redundant by https://github.com/D-Programming-Language/phobos/pull/513
	ulong getSize2(string name)
	{
		import win32.winnt;
		import win32.winbase;
/*
		auto h = CreateFileW(toUTF16z(name), FILE_READ_ATTRIBUTES, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		enforce(h!=INVALID_HANDLE_VALUE, new FileException(name));
		scope(exit) CloseHandle(h);
		LARGE_INTEGER li;
		enforce(GetFileSizeEx(h, &li), new FileException(name));
		return li.QuadPart;
*/

		WIN32_FILE_ATTRIBUTE_DATA fad;
		enforce(GetFileAttributesExW(toUTF16z(name), GET_FILEEX_INFO_LEVELS .GetFileExInfoStandard, &fad), new FileException(name));
		ULARGE_INTEGER li;
		li.LowPart  = fad.nFileSizeLow;
		li.HighPart = fad.nFileSizeHigh;
		return li.QuadPart;
	}
}
else
{
	alias std.file.getSize getSize2;
}

/// Using UNC paths bypasses path length limitation when using Windows wide APIs.
string longPath(string s)
{
	version (Windows)
	{
		if (!s.startsWith(`\\`))
			return `\\?\` ~ s.absolutePath().buildNormalizedPath().replace(`/`, `\`);
	}
	return s;
}

version (Windows)
{
	void hardLink(string src, string dst)
	{
		import win32.winnt;
		import win32.winbase;

		enforce(CreateHardLinkW(toUTF16z(dst), toUTF16z(src), null), new FileException(dst));
	}
}

ubyte[16] mdFile()(string fn)
{
	import std.md5, std.stdio;

	ubyte[16] digest;
	MD5_CTX context;
	context.start();

	version (Windows)
	{
		// avoid Unicode limitations of DigitalMars C runtime

		import win32.winnt;
		import win32.winbase;

		auto h = CreateFileW(toUTF16z(fn), GENERIC_READ, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		enforce(h!=INVALID_HANDLE_VALUE, new FileException(fn));
		scope(exit) CloseHandle(h);

		static ubyte[64 * 1024] buffer;
		while (true)
		{
			DWORD bytesRead;
			enforce(ReadFile(h, buffer.ptr, buffer.length, &bytesRead, null), new FileException(fn));
			if (!bytesRead)
				break;
			context.update(buffer[0..bytesRead]);
		}
	}
	else
	{
		auto f = File(fn);
		foreach (buffer; f.byChunk(64 * 1024))
			context.update(buffer);
		f.close();
	}

	context.finish(digest);
	return digest;
}
