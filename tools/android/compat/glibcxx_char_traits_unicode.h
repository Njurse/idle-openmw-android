// tools/android/compat/glibcxx_char_traits_unicode.h
//
// WHY THIS EXISTS
// ---------------
// MyGUI's UString is `std::basic_string<unsigned int>` (and at least one header, TextChangeHistory,
// carries an `std::basic_string<unsigned short>`), which needs the `std::char_traits`
// specialisations for those types. libc++ used to provide them and REMOVED them (the primary
// template is still *declared* in <__fwd/string.h> but has no definition), so on a modern NDK every
// translation unit that includes a MyGUI header fails:
//
//   error: implicit instantiation of undefined template 'std::char_traits<unsigned int>'
//     in MyGUI_TextChangeHistory.h:30 / MyGUI_UString.h:649 / :1005
//
// The Android dependency archive ships MyGUI 3.4.3 because that is what OpenMW requires
// (find_package(MyGUI 3.4.3 REQUIRED)), and 3.4.3 predates the removal, so the fix belongs here
// rather than in a MyGUI version bump we do not control.
//
// This restores the specialisations. It is deliberately written as explicit, complete
// specialisations of the standard template rather than a clever base class: libc++ only ever
// needed these to satisfy basic_string's string-ops, and every member below is the obvious
// character-wise operation for an unsigned integral type.
//
// Included with `-include` (see tools/android/configure-android.sh), so it lands before any
// standard header is instantiated with these types.
#ifndef IDLE_OPENMW_COMPAT_CHAR_TRAITS_UNICODE_H
#define IDLE_OPENMW_COMPAT_CHAR_TRAITS_UNICODE_H

#include <cstddef>
#include <cwchar>
#include <iosfwd>

namespace std
{

    template <class CharT>
    struct CharTraitsForUnsigned
    {
        using char_type = CharT;
        using int_type = unsigned long;
        using off_type = streamoff;
        using pos_type = streampos;
        using state_type = mbstate_t;

        static constexpr void assign(char_type& r, const char_type& a) noexcept { r = a; }

        static constexpr bool eq(char_type a, char_type b) noexcept { return a == b; }

        static constexpr bool lt(char_type a, char_type b) noexcept { return a < b; }

        static constexpr int compare(const char_type* s1, const char_type* s2, size_t n)
        {
            for (; n; --n, ++s1, ++s2)
            {
                if (lt(*s1, *s2))
                    return -1;
                if (lt(*s2, *s1))
                    return 1;
            }
            return 0;
        }

        static constexpr size_t length(const char_type* s)
        {
            size_t n = 0;
            for (; !eq(*s, char_type(0)); ++s)
                ++n;
            return n;
        }

        static constexpr const char_type* find(const char_type* s, size_t n, const char_type& a)
        {
            for (; n; --n, ++s)
                if (eq(*s, a))
                    return s;
            return nullptr;
        }

        static char_type* move(char_type* d, const char_type* s, size_t n)
        {
            if (n == 0)
                return d;
            if (d < s)
                for (size_t i = 0; i < n; ++i)
                    d[i] = s[i];
            else
                for (size_t i = n; i > 0; --i)
                    d[i - 1] = s[i - 1];
            return d;
        }

        static char_type* copy(char_type* d, const char_type* s, size_t n)
        {
            for (size_t i = 0; i < n; ++i)
                d[i] = s[i];
            return d;
        }

        static char_type* assign(char_type* d, size_t n, char_type a)
        {
            for (size_t i = 0; i < n; ++i)
                d[i] = a;
            return d;
        }

        static constexpr int_type not_eof(int_type c) noexcept
        {
            return eq_int_type(c, eof()) ? int_type(0) : c;
        }

        static constexpr char_type to_char_type(int_type c) noexcept { return char_type(c); }

        static constexpr int_type to_int_type(char_type c) noexcept { return int_type(c); }

        static constexpr bool eq_int_type(int_type a, int_type b) noexcept { return a == b; }

        static constexpr int_type eof() noexcept { return int_type(-1); }
    };

    // MyGUI's UString is built on `unsigned int`; TextChangeHistory also uses `unsigned short`.
    template <>
    struct char_traits<unsigned int> : CharTraitsForUnsigned<unsigned int>
    {
    };

    template <>
    struct char_traits<unsigned short> : CharTraitsForUnsigned<unsigned short>
    {
    };

}

#endif // IDLE_OPENMW_COMPAT_CHAR_TRAITS_UNICODE_H
