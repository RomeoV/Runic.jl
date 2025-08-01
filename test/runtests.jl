# SPDX-License-Identifier: MIT

using Runic:
    Runic, format_string
using Test:
    @test, @testset, @test_broken, @inferred, @test_throws
using JuliaSyntax:
    JuliaSyntax, @K_str, @KSet_str

@testset "Node" begin
    node = Runic.Node(JuliaSyntax.parseall(JuliaSyntax.GreenNode, "a = 1 + b\n"))

    # Pretty-printing
    @test sprint(show, node) == "Node({head: {kind: K\"toplevel\", flags: \"\"}, span: 10, tags: \"\"})"

    # JuliaSyntax duck-typing
    for n in (node, Runic.verified_kids(node)...)
        @test Runic.head(n) === JuliaSyntax.head(n) === n.head
        @test Runic.kind(n) === JuliaSyntax.kind(n) === n.head.kind
        @test Runic.flags(n) === JuliaSyntax.flags(n) === n.head.flags
        @test Runic.span(n) === JuliaSyntax.span(n) === n.span
    end
end

@testset "Runic.AssertionError" begin
    issuemsg = "This is unexpected, please file an issue with a reproducible example at " *
        "https://github.com/fredrikekre/Runic.jl/issues/new."
    try
        Runic.@assert 1 == 2
    catch err
        @test err isa Runic.AssertionError
        @test sprint(showerror, err) == "Runic.AssertionError: 1 == 2. " * issuemsg
    end
    try
        Runic.unreachable()
    catch err
        @test err isa Runic.AssertionError
        @test sprint(showerror, err) ==
            "Runic.AssertionError: unreachable code reached. " * issuemsg
    end
end

@testset "Chisels" begin
    # Type stability of verified_kids
    node = Runic.Node(JuliaSyntax.parseall(JuliaSyntax.GreenNode, "a = 1 + b\n"))
    @test typeof(@inferred Runic.verified_kids(node)) === Vector{Runic.Node}

    # replace_bytes!: insert larger
    io = IOBuffer(); write(io, "abc"); seek(io, 1)
    p = position(io)
    Runic.replace_bytes!(io, "xx", 1)
    @test p == position(io)
    @test read(io, String) == "xxc"
    seekstart(io)
    @test read(io, String) == "axxc"
    # replace_bytes!: insert smaller
    io = IOBuffer(); write(io, "abbc"); seek(io, 1)
    p = position(io)
    Runic.replace_bytes!(io, "x", 2)
    @test p == position(io)
    @test read(io, String) == "xc"
    seekstart(io)
    @test read(io, String) == "axc"
    # replace_bytes!: insert same
    io = IOBuffer(); write(io, "abc"); seek(io, 1)
    p = position(io)
    Runic.replace_bytes!(io, "x", 1)
    @test p == position(io)
    @test read(io, String) == "xc"
    seekstart(io)
    @test read(io, String) == "axc"
end

@testset "JuliaSyntax assumptions" begin
    # Duplicates are kept in KSet
    @test KSet"; ;" == (K";", K";")
    @test KSet"Whitespace ; Whitespace" == (K"Whitespace", K";", K"Whitespace")
end

@testset "syntax tree normalization" begin
    function rparse(str)
        node = Runic.Node(JuliaSyntax.parseall(JuliaSyntax.GreenNode, str))
        Runic.normalize_tree!(node)
        return node
    end
    function check_no_leading_trailing_ws(node)
        Runic.is_leaf(node) && return
        kids = Runic.verified_kids(node)
        if length(kids) > 0
            @test !JuliaSyntax.is_whitespace(kids[1])
            @test !JuliaSyntax.is_whitespace(kids[end])
        end
        for kid in kids
            check_no_leading_trailing_ws(kid)
        end
    end
    # Random things found in the ecosystem
    str = "[\n    # c\n    0.5 1.0\n    1.0 2.0\n    # c\n]"
    check_no_leading_trailing_ws(rparse(str))
    str = "[0.5 1.0; 1.0 2.0;;; 4.5 6.0; 6.0 8.0]"
    check_no_leading_trailing_ws(rparse(str))
end

@testset "Trailing whitespace" begin
    io = IOBuffer()
    println(io, "a = 1  ") # Trailing space
    println(io, "b = 2\t") # Trailing tab
    println(io, "  ") # Trailing space on consecutive lines
    println(io, "  ")
    str = String(take!(io))
    @test format_string(str) == "a = 1\nb = 2\n\n\n"
    # Trailing whitespace just before closing indent token
    @test format_string("begin\n    a = 1 \nend") == "begin\n    a = 1\nend"
    @test format_string("let\n    a = 1 \nend") == "let\n    a = 1\nend"
    # Trailing whitespace in comments
    @test format_string("# comment ") == format_string("# comment  ") ==
        format_string("# comment\t") == format_string("# comment\t\t") ==
        format_string("# comment \t ") == format_string("# comment\t \t") == "# comment"
end

@testset "space before comment" begin
    for sp in ("", " ", "  ")
        csp = sp == "" ? " " : sp
        @test format_string("a$(sp)# comment") == "a$(csp)# comment"
        @test format_string("1 + 1$(sp)# comment") == "1 + 1$(csp)# comment"
        @test format_string("(a,$(sp)# comment\nb)") ==
            "(\n    a,$(csp)# comment\n    b,\n)"
        # Edgecases where the comment ends up as the first leaf inside a node
        @test format_string("(a,$(sp)# comment\nb + b)") ==
            "(\n    a,$(csp)# comment\n    b + b,\n)"
        @test format_string("if c$(sp)# a\n    b\nend") == "if c$(csp)# a\n    b\nend"
        # Allow no space after opening brackets
        # (https://github.com/fredrikekre/Runic.jl/issues/81)
        for (o, c) in (("(", ")"), ("[", "]"), ("{", "}"))
            @test format_string("$(o)$(sp)#= a =#$(sp)$(c)") == "$(o)$(sp)#= a =#$(c)"
        end
    end
    let str = "a = 1  # a comment\nab = 2 # ab comment\n"
        @test format_string(str) == str
    end
end

@testset "Hex/oct/bin literal integers" begin
    z(n) = "0"^n
    test_cases = [
        # Hex UInt8
        ("0x" * z(n) * "1" => "0x01" for n in 0:1)...,
        # Hex  UInt16
        ("0x" * z(n) * "1" => "0x0001" for n in 2:3)...,
        # Hex  UInt32
        ("0x" * z(n) * "1" => "0x00000001" for n in 4:7)...,
        # Hex  UInt64
        ("0x" * z(n) * "1" => "0x0000000000000001" for n in 8:15)...,
        # Hex UInt128
        ("0x" * z(n) * "1" => "0x" * z(31) * "1" for n in 16:31)...,
        # Hex BigInt
        ("0x" * z(n) * "1" => "0x" * z(n) * "1" for n in 32:35)...,
    ]
    mod = Module()
    for (a, b) in test_cases
        c = Core.eval(mod, Meta.parse(a))
        d = Core.eval(mod, Meta.parse(b))
        @test c == d
        @test typeof(c) == typeof(d)
        @test format_string(a) == b
    end
end

@testset "Floating point literals" begin
    test_cases = [
        ["1.0", "1.", "01.", "001.", "001.00", "1.00"] => "1.0",
        ["0.1", ".1", ".10", ".100", "00.100", "0.10"] => "0.1",
        ["1.1", "01.1", "1.10", "1.100", "001.100", "01.10"] => "1.1",
    ]
    for a in ("e", "E", "f"), b in ("", "+", "-"), c in ("3", "0", "12")
        abc = a * b * c
        abc′ = replace(abc, "E" => "e")
        push!(
            test_cases,
            ["1$(abc)", "01$(abc)", "01.$(abc)", "1.$(abc)", "1.000$(abc)", "01.00$(abc)"] => "1.0$(abc′)"
        )
    end
    mod = Module()
    for prefix in ("", "-", "+")
        for (as, b) in test_cases
            b = prefix * b
            for a in as
                a = prefix * a
                c = Core.eval(mod, Meta.parse(a))
                d = Core.eval(mod, Meta.parse(b))
                @test c == d
                @test typeof(c) == typeof(d)
                @test format_string(a) == b
            end
        end
    end
    # Issue #137: '−' (Unicode U+2212) is a synonym in the parser to the normally used
    # '-' (ASCII/Unicode U+002D)
    @test format_string("\u22121.0") == "-1.0"
    @test format_string("1.0e\u22121") == "1.0e-1"
    @test format_string("\u22121.0e\u22121") == "-1.0e-1"
end

@testset "whitespace between operators" begin
    for sp in ("", " ", "  ")
        for op in ("+", "-", "==", "!=", "===", "!==", "<", "<=", ".+", ".==")
            # a op b
            @test format_string("$(sp)a$(sp)$(op)$(sp)b$(sp)") ==
                "$(sp)a $(op) b$(sp)"
            # x = a op b
            @test format_string("$(sp)x$(sp)=$(sp)a$(sp)$(op)$(sp)b$(sp)") ==
                "$(sp)x = a $(op) b$(sp)"
            # a op b op c
            @test format_string("$(sp)a$(sp)$(op)$(sp)b$(sp)$(op)$(sp)c$(sp)") ==
                "$(sp)a $(op) b $(op) c$(sp)"
            # a op b other_op c
            @test format_string("$(sp)a$(sp)$(op)$(sp)b$(sp)*$(sp)c$(sp)") ==
                "$(sp)a $(op) b * c$(sp)"
            # a op (b other_op c)
            @test format_string("$(sp)a$(sp)$(op)$(sp)($(sp)b$(sp)*$(sp)c$(sp))$(sp)") ==
                "$(sp)a $(op) (b * c)$(sp)"
            # call() op call()
            @test format_string("$(sp)sin(α)$(sp)$(op)$(sp)cos(β)$(sp)") ==
                "$(sp)sin(α) $(op) cos(β)$(sp)"
            # call() op call() op call()
            @test format_string("$(sp)sin(α)$(sp)$(op)$(sp)cos(β)$(sp)$(op)$(sp)tan(γ)$(sp)") ==
                "$(sp)sin(α) $(op) cos(β) $(op) tan(γ)$(sp)"
            # a op \n b
            @test format_string("$(sp)a$(sp)$(op)$(sp)\nb$(sp)") ==
                "$(sp)a $(op)\n    b$(sp)"
            # a op # comment \n b
            minspace = sp == "" ? " " : sp
            @test format_string("$(sp)a$(sp)$(op)$(sp)# comment\nb$(sp)") ==
                "$(sp)a $(op)$(minspace)# comment\n    b$(sp)"
        end
        # Exceptions to the rule: `:` and `^`
        # a:b
        @test format_string("$(sp)a$(sp):$(sp)b$(sp)") == "$(sp)a:b$(sp)"
        @test format_string("$(sp)a + a$(sp):$(sp)b + b$(sp)") == "$(sp)(a + a):(b + b)$(sp)"
        @test format_string("$(sp)(1 + 2)$(sp):$(sp)(1 + 3)$(sp)") ==
            "$(sp)(1 + 2):(1 + 3)$(sp)"
        # a:b:c
        @test format_string("$(sp)a$(sp):$(sp)b$(sp):$(sp)c$(sp)") == "$(sp)a:b:c$(sp)"
        @test format_string("$(sp)(1 + 2)$(sp):$(sp)(1 + 3)$(sp):$(sp)(1 + 4)$(sp)") ==
            "$(sp)(1 + 2):(1 + 3):(1 + 4)$(sp)"
        # a^b
        @test format_string("$(sp)a$(sp)^$(sp)b$(sp)") == "$(sp)a^b$(sp)"
        # Edgecase when formatting whitespace in the next leaf, when the next leaf is a
        # grand child or even younger. Note that this test depends a bit on where
        # JuliaSyntax.jl decides to place the K"Whitespace" node.
        @test format_string("$(sp)a$(sp)+$(sp)b$(sp)*$(sp)c$(sp)/$(sp)d$(sp)") ==
            "$(sp)a + b * c / d$(sp)"
        # Edgecase when using whitespace from the next leaf but the call chain continues
        # after with more children.
        @test format_string("$(sp)z$(sp)+$(sp)2x$(sp)+$(sp)z$(sp)") == "$(sp)z + 2x + z$(sp)"
        # Edgecase where the NewlineWs ends up inside the second call in a chain
        @test format_string("$(sp)a$(sp)\\$(sp)b$(sp)≈ $(sp)\n$(sp)c$(sp)\\$(sp)d$(sp)") ==
            "$(sp)a \\ b ≈\n    c \\ d$(sp)"
        # Edgecase with call-call-newline as a leading sequence
        @test format_string("(\na$(sp)*$(sp)b$(sp)=>$(sp)c,\n)") == "(\n    a * b => c,\n)"
    end
end

@testset "spaces in listlike" begin
    for sp in ("", " ", "  "), a in ("a", "a + a", "a(x)"), b in ("b", "b + b", "b(y)")
        csp = sp == "" ? " " : sp # at least one space before comment (but more allowed)
        # tuple, call, dotcall, vect, ref
        for (o, c) in (("(", ")"), ("f(", ")"), ("@f(", ")"), ("f.(", ")"), ("[", "]"), ("T[", "]"))
            tr = o in ("f(", "@f(", "f.(") ? "" : ","
            # single line
            @test format_string("$(o)$(sp)$(c)") == "$(o)$(c)"
            @test format_string("$(o)$(sp)$(a)$(sp),$(sp)$(b)$(sp)$(c)") ==
                format_string("$(o)$(sp)$(a)$(sp),$(sp)$(b)$(sp),$(sp)$(c)") ==
                "$(o)$(a), $(b)$(c)"
            # comments on the same line
            @test format_string("$(o)$(sp)$(a)$(sp), #==#$(sp)$(b)$(sp)$(c)") ==
                "$(o)$(a), #==# $(b)$(c)"
            @test format_string("$(o)$(sp)$(a) #==#,$(sp)$(b)$(sp)$(c)") ==
                "$(o)$(a) #==#, $(b)$(c)"
            @test format_string("$(o)$(sp)$(a)#==# = 1$(sp)$(c)") ==
                "$(o)$(a) #==# = 1$(c)"
            # line break in between items
            @test format_string("$(o)$(sp)$(a)$(sp),\n$(sp)$(b)$(sp)$(c)") ==
                "$(o)\n    $(a),\n    $(b)$(tr)\n$(c)"
            @test format_string("$(o)$(sp)$(a)$(sp),\n$(sp)$(b)$(sp),$(sp)$(c)") ==
                "$(o)\n    $(a),\n    $(b),\n$(c)"
            # line break after opening token
            @test format_string("$(o)\n$(sp)$(a)$(sp),$(sp)$(b)$(sp)$(c)") ==
                "$(o)\n    $(a), $(b)$(tr)\n$(c)"
            @test format_string("$(o)\n$(sp)$(a)$(sp),$(sp)$(b)$(sp),$(c)") ==
                "$(o)\n    $(a), $(b),\n$(c)"
            # line break before closing token
            @test format_string("$(o)$(sp)$(a)$(sp),$(sp)$(b)\n$(c)") ==
                "$(o)\n    $(a), $(b)$(tr)\n$(c)"
            @test format_string("$(o)$(sp)$(a)$(sp),$(sp)$(b),\n$(c)") ==
                "$(o)\n    $(a), $(b),\n$(c)"
            # line break after opening and before closing token
            @test format_string("$(o)\n$(sp)$(a)$(sp),$(sp)$(b)\n$(c)") ==
                "$(o)\n    $(a), $(b)$(tr)\n$(c)"
            @test format_string("$(o)\n$(sp)$(a)$(sp),$(sp)$(b),\n$(c)") ==
                "$(o)\n    $(a), $(b),\n$(c)"
            # line break after opening and before closing token and between items
            @test format_string("$(o)\n$(sp)$(a)$(sp),\n$(sp)$(b)\n$(c)") ==
                "$(o)\n    $(a),\n    $(b)$(tr)\n$(c)"
            @test format_string("$(o)\n$(sp)$(a)$(sp),\n$(sp)$(b),\n$(c)") ==
                "$(o)\n    $(a),\n    $(b),\n$(c)"
            # trailing comments
            @test format_string("$(o)$(sp)# x\n$(sp)$(a)$(sp),$(sp)# a\n$(sp)$(b)$(sp)# b\n$(c)") ==
                "$(o)$(sp)# x\n    $(a),$(csp)# a\n    $(b)$(tr)$(csp)# b\n$(c)"
            @test format_string("$(o)$(sp)# x\n$(sp)$(a)$(sp),$(sp)# a\n$(sp)$(b),$(sp)# b\n$(c)") ==
                "$(o)$(sp)# x\n    $(a),$(csp)# a\n    $(b),$(csp)# b\n$(c)"
            @test format_string("$(o)$(sp)#= x =#$(sp)$(a)$(sp),$(sp)# a\n$(sp)$(b),$(sp)# b\n$(c)") ==
                "$(o)\n    #= x =# $(a),$(csp)# a\n    $(b),$(csp)# b\n$(c)"
            @test format_string("$(o)$(sp)#= x =#\n$(a)$(sp),$(sp)# a\n$(sp)$(b),$(sp)# b\n$(c)") ==
                "$(o)$(sp)#= x =#\n    $(a),$(csp)# a\n    $(b),$(csp)# b\n$(c)"
            # comments on separate lines between items
            @test format_string("$(o)\n# a\n$(a)$(sp),\n# b\n$(b)\n$(c)") ==
                "$(o)\n    # a\n    $(a),\n    # b\n    $(b)$(tr)\n$(c)"
            @test format_string("$(o)\n# a\n$(a)$(sp),\n# b\n$(b)$(sp),\n$(c)") ==
                "$(o)\n    # a\n    $(a),\n    # b\n    $(b),\n$(c)"
            # comma on next line (TODO: move them up?)
            @test format_string("$(o)\n$(a)$(sp)\n,$(sp)$(b)\n$(c)") ==
                "$(o)\n    $(a)\n    , $(b)$(tr)\n$(c)"
        end
        # parens (but not block)
        @test format_string("($(sp)$(a)$(sp))") == "($(a))"
        @test format_string("($(sp)\n$(sp)$(a)$(sp)\n$(sp))") == "(\n    $(a)\n)"
        @test format_string("($(sp)\n$(sp)$(a)$(sp);$(sp)$(b)\n$(sp))") == "(\n    $(a); $(b)\n)"
        # Implicit tuple (no parens)
        begin
            @test format_string("$(a)$(sp),$(sp)$(b)") == "$(a), $(b)"
            @test format_string("$(a)$(sp), #==#$(sp)$(b)") == "$(a), #==# $(b)"
            @test format_string("$(a) #==#,$(sp)$(b)") == "$(a) #==#, $(b)"
            @test format_string("$(a)$(sp),\n$(sp)$(b)") == "$(a),\n    $(b)"
            # trailing comments
            @test format_string("$(a)$(sp),$(sp)# a\n$(sp)$(b)$(sp)# b") ==
                "$(a),$(csp)# a\n    $(b)$(csp)# b"
            @test format_string("# a\n$(a)$(sp),\n# b\n$(b)") ==
                "# a\n$(a),\n    # b\n    $(b)"
        end
        # Single item with trailing `,` and `;`
        @test format_string("($(sp)$(a)$(sp),$(sp))") == "($(a),)"
        @test format_string("f($(sp)$(a)$(sp),$(sp))") ==
            format_string("f($(sp)$(a)$(sp);$(sp))") == "f($(a))"
        # Keyword arguments
        @test format_string("f($(sp)$(a)$(sp);$(sp)$(b)$(sp))") ==
            format_string("f($(sp)$(a)$(sp);$(sp)$(b)$(sp),$(sp))") ==
            "f($(a); $(b))"
        @test format_string("f(\n$(sp)$(a)$(sp);\n$(sp)$(b)$(sp)\n)") ==
            "f(\n    $(a);\n    $(b)\n)"
        @test format_string("f(\n$(sp)$(a)$(sp);\n$(sp)$(b)$(sp),$(sp)\n)") ==
            "f(\n    $(a);\n    $(b),\n)"
        @test format_string("f($(sp)$(a)$(sp);$(sp)b$(sp)=$(sp)$(b)$(sp))") ==
            format_string("f($(sp)$(a)$(sp);$(sp)b$(sp)=$(sp)$(b)$(sp),$(sp))") ==
            "f($(a); b = $(b))"
        @test format_string("f(\n$(sp)$(a)$(sp);\n$(sp)b$(sp)=$(sp)$(b)$(sp)\n)") ==
            "f(\n    $(a);\n    b = $(b)\n)"
        @test format_string("f(\n$(sp)$(a)$(sp);\n$(sp)b$(sp)=$(sp)$(b)$(sp),$(sp)\n)") ==
            "f(\n    $(a);\n    b = $(b),\n)"
        @test format_string("f(\n$(sp)$(a)$(sp);$(sp)b$(sp)=$(sp)$(b)$(sp)\n)") ==
            "f(\n    $(a); b = $(b)\n)"
        @test format_string("f(\n$(sp)$(a)$(sp);$(sp)b$(sp)=$(sp)$(b)$(sp),$(sp)\n)") ==
            "f(\n    $(a); b = $(b),\n)"
        # Keyword arguments only with semi-colon on the same line as opening paren
        @test format_string("f(;\n$(sp)b$(sp)=$(sp)$(b)$(sp)\n)") ==
            format_string("f(;$(sp)b$(sp)=$(sp)$(b)$(sp)\n)") ==
            "f(;\n    b = $(b)\n)"
        @test format_string("f(;\n$(sp)b$(sp)=$(sp)$(b)$(sp),$(sp)\n)") ==
            format_string("f(;$(sp)b$(sp)=$(sp)$(b)$(sp),$(sp)\n)") ==
            "f(;\n    b = $(b),\n)"
        # vect/ref with parameter (not valid Julia syntax, but parses)
        for T in ("", "T")
            @test format_string("$(T)[$(sp)$(a),$(sp)$(b)$(sp);$(sp)]") ==
                "$(T)[$(a), $(b)]"
            @test format_string("$(T)[$(sp)$(a),$(sp)$(b)$(sp);$(sp)a=$(a)$(sp)]") ==
                "$(T)[$(a), $(b); a = $(a)]"
            @test format_string("$(T)[$(sp)$(a),$(sp)$(b)$(sp);$(sp)a=$(a)$(sp),$(sp)b=$(b)$(sp)]") ==
                "$(T)[$(a), $(b); a = $(a), b = $(b)]"
        end
        # Multple `;` in argument list (lowering error but parses....)
        @test format_string("f($(sp)x$(sp);$(sp)y$(sp)=$(sp)$(a)$(sp);$(sp)z$(sp)=$(sp)$(b)$(sp))") ==
            "f(x; y = $(a); z = $(b))"
    end
    # Splatting
    for sp in ("", " ", "  ")
        @test format_string("($(sp)a$(sp)...,$(sp))") == "(a$(sp)...,)"
        @test format_string("f($(sp)a$(sp)...,$(sp))") == "f(a$(sp)...)"
        @test format_string("f($(sp)a$(sp)...;$(sp)b$(sp)...$(sp))") == "f(a$(sp)...; b$(sp)...)"
    end
    # Named tuples
    for sp in ("", " ", "  "), a in ("a", "a = 1")
        @test format_string("($(sp);$(sp)$(a)$(sp))") ==
            format_string("($(sp);$(sp)$(a)$(sp),$(sp))") == "(; $(a))"
        for b in ("b", "b = 2")
            @test format_string("($(sp);$(sp)$(a)$(sp),$(sp)$(b)$(sp))") ==
                format_string("($(sp);$(sp)$(a)$(sp),$(sp)$(b)$(sp),$(sp))") ==
                "(; $(a), $(b))"
        end
        @test format_string("($(sp);$(sp))") == "(;)"
        @test format_string("($(sp); #= a =#$(sp))") == "(; #= a =#)"
    end
    # KSet"curly braces bracescat" (not as extensive testing as tuple/call/dotcall above but
    # the code path is the same)
    for x in ("", "X"), sp in ("", " ", "  "), a in ("A", "<:B", "C <: D"), b in ("E", "<:F", "G <: H")
        tr = x == "" ? "" : ","
        @test format_string("$(x){$(sp)$(a)$(sp),$(sp)$(b)$(sp)}") == "$(x){$(a), $(b)}"
        @test format_string("$(x){$(sp)$(a)$(sp);$(sp)$(b)$(sp)}") == "$(x){$(a); $(b)}"
        @test format_string("$(x){$(sp)$(a)$(sp);$(sp)$(b)$(sp)}") == "$(x){$(a); $(b)}"
        @test format_string("$(x){$(sp)$(a)$(sp),$(sp)$(a)$(sp);$(sp)$(b)$(sp)}") ==
            "$(x){$(a), $(a); $(b)}"
        @test format_string("$(x){\n$(sp)$(a)$(sp);$(sp)$(b)$(sp)\n}") ==
            "$(x){\n    $(a); $(b)$(tr)\n}"
        @test format_string("$(x){\n$(sp)$(a)$(sp),$(sp)$(a)$(sp);$(sp)$(b)$(sp)\n}") ==
            "$(x){\n    $(a), $(a); $(b),\n}"
    end
    # Trailing `;` in paren-block
    @test format_string("(a = A;)") == "(a = A;)"
    @test format_string("cond && (a = A;)") == "cond && (a = A;)"
    @test format_string("(a = A; b = B;)") == "(a = A; b = B)"
    @test format_string("(a = A;;)") == "(a = A;)"
    @test format_string("(;;)") == format_string("( ; ; )") == "(;;)"
    @test format_string("(;)") == format_string("( ; )") == "(;)"
    @test format_string("(@a b(c);)") == "(@a b(c);)"
    # https://github.com/fredrikekre/Runic.jl/issues/16
    @test format_string("(i for i in\nI)") == "(\n    i for i in\n        I\n)"
    @test format_string("f(i for i in\nI)") == "f(\n    i for i in\n        I\n)"
    # Parenthesized macrocalls with keyword arguments
    for sp in ("", " ", "  ")
        @test format_string("@f($(sp)a$(sp);$(sp)b$(sp))") == "@f(a; b)"
        @test format_string("@f($(sp)a$(sp);$(sp)b = 1$(sp))") == "@f(a; b = 1)"
        @test format_string("@f($(sp);$(sp)b$(sp))") == "@f(; b)"
    end
    # https://github.com/fredrikekre/Runic.jl/issues/32
    @test format_string("f(@m begin\nend)") == "f(\n    @m begin\n    end\n)"
    @test format_string("f(@m(begin\nend))") == "f(\n    @m(\n        begin\n        end\n    )\n)"
    @test format_string("f(r\"\"\"\nf\n\"\"\")") == "f(\n    r\"\"\"\n    f\n    \"\"\"\n)"
    @test format_string("f(```\nf\n```)") == "f(\n    ```\n    f\n    ```\n)"
    @test format_string("f(x```\nf\n```)") == "f(\n    x```\n    f\n    ```\n)"
    @test format_string("(a, @m begin\nend)") == "(\n    a, @m begin\n    end\n)"
    @test format_string("(\na, x -> @m x[i]\n)") == "(\n    a, x -> @m x[i]\n)"
    @test format_string("(\na, x -> @m(x[i])\n)") == "(\n    a, x -> @m(x[i]),\n)"
    # Weird cornercase where a trailing comma messes some cases up (don't recall...)
    @test format_string("{\n@f\n}") == "{\n    @f\n}"
    # Non space whitespace (TODO: Not sure if a JuliaSyntax bug or not?)
    @test format_string(String(UInt8[0x61, 0x20, 0x3d, 0x3d, 0x20, 0xc2, 0xa0, 0x62, 0x3a, 0x63])) ==
        "a == b:c"
    # Edge case with comment and no items
    @test format_string("[# a\n]") == "[# a\n]"
    @test format_string("[ # a\n]") == "[ # a\n]"
    # https://github.com/fredrikekre/Runic.jl/issues/151
    @test format_string("(\n    a, b for b in B\n)") == "(\n    a, b for b in B\n)"
end

@testset "whitespace in let" begin
    for sp in ("", " ", "  ")
        msp = sp == "" ? " " : sp
        @test format_string("let$(sp)\nend") == "let\nend"
        @test format_string("let @inline a() = 1\nend") == "let @inline a() = 1\nend"
        for a in ("a", "a = 1", "a() = 1", "\$a"), b in ("b", "b = 2")
            @test format_string("let $(sp)$(a)$(sp),$(sp)$(b)\nend") == "let $(a), $(b)\nend"
            @test format_string("let $(sp)$(a),$(sp)$(b)\nend") == "let $(a), $(b)\nend"
            @test format_string("let $(sp)$(a)$(sp),\n$(sp)$(b)\nend") == "let $(a),\n        $(b)\nend"
            # Comments
            @test format_string("let $(sp)$(a)$(sp)#=c=#$(sp),$(sp)$(b)\nend") == "let $(a)$(msp)#=c=#, $(b)\nend"
            @test format_string("let $(sp)$(a)$(sp),$(sp)#=c=#$(sp)$(b)\nend") == "let $(a),$(msp)#=c=# $(b)\nend"
        end
    end
end

@testset "whitespace around ->" begin
    for sp in ("", " ", "  ")
        @test format_string("a$(sp)->$(sp)b") == "a -> b"
    end
end

@testset "whitespace around ternary" begin
    for sp in (" ", "  ")
        @test format_string("a$(sp)?$(sp)b$(sp):$(sp)c") == "a ? b : c"
        @test format_string("a$(sp)?\nb$(sp):\nc") == "a ?\n    b :\n    c"
        @test format_string("a$(sp)?$(sp)b$(sp):$(sp)c$(sp)?$(sp)d$(sp):$(sp)e") ==
            "a ? b : c ? d : e"
        @test format_string("a$(sp)?\nb$(sp):\nc$(sp)?\nd$(sp):\ne") ==
            "a ?\n    b :\n    c ?\n    d :\n    e"
        # Comment in x-position
        @test format_string("a$(sp)?$(sp)b$(sp)#==#$(sp):\nc") == "a ? b #==# :\n    c"
        # Comment in other-position
        @test format_string("a$(sp)?$(sp)#==#$(sp)b$(sp):\nc") == "a ? #==# b :\n    c"
    end
end

@testset "whitespace in comparison chains" begin
    for sp in ("", " ", "  ")
        @test format_string("a$(sp)==$(sp)b") == "a == b"
        @test format_string("a$(sp)==$(sp)b$(sp)==$(sp)c") == "a == b == c"
        @test format_string("a$(sp)<=$(sp)b$(sp)==$(sp)c") == "a <= b == c"
        @test format_string("a$(sp)<=$(sp)b$(sp)>=$(sp)c") == "a <= b >= c"
        @test format_string("a$(sp)<$(sp)b$(sp)>=$(sp)c") == "a < b >= c"
        @test format_string("a$(sp)<$(sp)b$(sp)<$(sp)c") == "a < b < c"
        # Dotted chains
        @test format_string("a$(sp).<=$(sp)b$(sp).>=$(sp)c") == "a .<= b .>= c"
        @test format_string("a$(sp).<$(sp)b$(sp).<$(sp)c") == "a .< b .< c"
    end
end

@testset "whitespace around assignments" begin
    # Regular assignments and dot-assignments
    for a in ("=", "+=", "-=", ".=", ".+=", ".-=")
        @test format_string("a$(a)b") == "a $(a) b"
        @test format_string("a $(a)b") == "a $(a) b"
        @test format_string("a$(a) b") == "a $(a) b"
        @test format_string("  a$(a) b") == "  a $(a) b"
        @test format_string("  a$(a) b  ") == "  a $(a) b  "
        @test format_string("a$(a)   b") == "a $(a) b"
        @test format_string("a$(a)   b  *  x") == "a $(a) b * x"
        @test format_string("a$(a)( b *  x)") == "a $(a) (b * x)"
    end
    # Chained assignments
    @test format_string("x=a= b  ") == "x = a = b  "
    @test format_string("a=   b = x") == "a = b = x"
    # Check the common footgun of permuting the operator and =
    @test format_string("a =+ c") == "a = + c"
    # Short form function definitions
    @test format_string("sin(π)=cos(pi)") == "sin(π) = cos(pi)"
    # For loop nodes are assignment, even when using `in` and `∈`
    for op in ("in", "=", "∈"), sp in ("", " ", "  ")
        op == "in" && sp == "" && continue
        @test format_string("for i$(sp)$(op)$(sp)1:10\nend\n") == "for i in 1:10\nend\n"
    end
    # Quoted assignment operators
    @test format_string(":(=)") == ":(=)"
    @test format_string(":(+=)") == ":(+=)"
end

@testset "whitespace around <: and >:, no whitespace around ::" begin
    # K"::" with both LHS and RHS
    @test format_string("a::T") == "a::T"
    @test format_string("a::T::S") == "a::T::S"
    @test format_string("a  ::  T") == "a::T"
    # K"::" with just RHS
    @test format_string("f(::T)::T = 1") == "f(::T)::T = 1"
    @test format_string("f(:: T) :: T = 1") == "f(::T)::T = 1"
    # K"<:" and K">:" with both LHS and RHS
    @test format_string("a<:T") == "a <: T"
    @test format_string("a>:T") == "a >: T"
    @test format_string("a  <:   T") == "a <: T"
    @test format_string("a  >:   T") == "a >: T"
    # K"<:" and K">:" with just RHS
    @test format_string("V{<:T}") == "V{<:T}"
    @test format_string("V{<: T}") == "V{<:T}"
    @test format_string("V{>:T}") == "V{>:T}"
    @test format_string("V{>: T}") == "V{>:T}"
    # K"comparison" for chains
    @test format_string("a<:T<:S") == "a <: T <: S"
    @test format_string("a>:T>:S") == "a >: T >: S"
    @test format_string("a <:  T   <:    S") == "a <: T <: S"
    @test format_string("a >:  T   >:    S") == "a >: T >: S"
end

@testset "spaces around keywords" begin
    for sp in (" ", "  ")
        @test format_string("struct$(sp)A end") == "struct A end"
        @test format_string("mutable$(sp)struct$(sp)A end") == "mutable struct A end"
        @test format_string("abstract$(sp)type$(sp)A end") == "abstract type A end"
        @test format_string("primitive$(sp)type$(sp)A 64 end") == "primitive type A 64 end"
        @test format_string("function$(sp)A() end") == "function A() end"
        @test format_string("if$(sp)a\nelseif$(sp)b\nend") == "if a\nelseif b\nend"
        @test format_string("if$(sp)a && b\nelseif$(sp)c || d\nend") == "if a && b\nelseif c || d\nend"
        @test format_string("try\nerror()\ncatch$(sp)e\nend") == "try\n    error()\ncatch e\nend"
        @test format_string("A$(sp)where$(sp){T}") == "A where {T}"
        @test format_string("A$(sp)where$(sp){T}$(sp)where$(sp){S}") == "A where {T} where {S}"
        @test format_string("f()$(sp)do$(sp)x\ny\nend") == "f() do x\n    y\nend"
        @test format_string("f()$(sp)do\ny\nend") == "f() do\n    y\nend"
        @test format_string("f()$(sp)do; y end") == "f() do;\n    y\nend"
        @test format_string("function f()\n    return$(sp)1\nend") == "function f()\n    return 1\nend"
        @test format_string("function f()\n    return$(sp)\nend") == "function f()\n    return\nend"
        @test format_string("module$(sp)A\nend") == "module A\nend"
        @test format_string("module$(sp)(A)\nend") == "module (A)\nend"
        @test format_string("let$(sp)x = 1\nend") == "let x = 1\nend"
        @test format_string("let$(sp)\nend") == "let\nend"
        for word in ("local", "global"), rhs in ("a", "a, b", "a = 1", "a, b = 1, 2")
            word == "const" && rhs in ("a", "a, b") && continue
            @test format_string("$(word)$(sp)$(rhs)") == "$(word) $(rhs)"
            # After `local`, `global`, and `const` a newline can be used instead of a space
            @test format_string("$(word)$(sp)\n$(sp)$(rhs)") == "$(word)\n    $(rhs)"
        end
        @test format_string("global\n\nx = 1") == "global\n\n    x = 1"
        @test format_string("local\n\nx = 1") == "local\n\n    x = 1"
        @test format_string("const$(sp)x = 1") == "const x = 1"
        # After `where` a newline can be used instead of a space
        @test format_string("A$(sp)where$(sp)\n{A}") == "A where\n{A}"
    end
    @test format_string("try\nerror()\ncatch\nend") == "try\n    error()\ncatch\nend"
    @test format_string("A where{T}") == "A where {T}"
    @test format_string("A{T}where{T}") == "A{T} where {T}"
    # Some keywords can have a parenthesized expression directly after without the space...
    @test format_string("if(a)\nelseif(b)\nend") == "if (a)\nelseif (b)\nend"
    @test format_string("while(a)\nend") == "while (a)\nend"
    @test format_string("function f()\n    return(1)\nend") == "function f()\n    return (1)\nend"
    @test format_string("local(a)") == "local (a)"
    @test format_string("global(a)") == "global (a)"
    @test format_string("module(A)\nend") == "module (A)\nend"
end

@testset "replace ∈ and = with in in for loops and generators" begin
    for sp in ("", " ", "  "), op in ("∈", "=", "in")
        op == "in" && sp == "" && continue
        # for loops
        @test format_string("for i$(sp)$(op)$(sp)I\nend") == "for i in I\nend"
        @test format_string("for i$(sp)$(op)$(sp)I, j$(sp)$(op)$(sp)J\nend") ==
            "for i in I, j in J\nend"
        @test format_string("for i$(sp)$(op)$(sp)I, j$(sp)$(op)$(sp)J, k$(sp)$(op)$(sp)K\nend") ==
            "for i in I, j in J, k in K\nend"
        # for generators, filter
        for (l, r) in (("[", "]"), ("(", ")"))
            @test format_string("$(l)i for i$(sp)$(op)$(sp)I$(r)") == "$(l)i for i in I$(r)"
            # cartesian
            @test format_string("$(l)(i, j) for i$(sp)$(op)$(sp)I, j$(sp)$(op)$(sp)J$(r)") ==
                "$(l)(i, j) for i in I, j in J$(r)"
            @test format_string("$(l)(i, j, k) for i$(sp)$(op)$(sp)I, j$(sp)$(op)$(sp)J, k$(sp)$(op)$(sp)K$(r)") ==
                "$(l)(i, j, k) for i in I, j in J, k in K$(r)"
            @test format_string("$(l)(i, j, k) for i$(sp)$(op)$(sp)I for j$(sp)$(op)$(sp)J, k$(sp)$(op)$(sp)K$(r)") ==
                "$(l)(i, j, k) for i in I for j in J, k in K$(r)"
            # multiple for
            @test format_string("$(l)(i, j) for i$(sp)$(op)$(sp)I for j$(sp)$(op)$(sp)J$(r)") ==
                "$(l)(i, j) for i in I for j in J$(r)"
            @test format_string("$(l)(i, j, k) for i$(sp)$(op)$(sp)I for j$(sp)$(op)$(sp)J for k$(sp)$(op)$(sp)K$(r)") ==
                "$(l)(i, j, k) for i in I for j in J for k in K$(r)"
        end
        # K"filter"
        for (l, r) in (("[", "]"), ("(", ")"))
            @test format_string("$(l)i for i$(sp)$(op)$(sp)I if i < 2$(r)") ==
                "$(l)i for i in I if i < 2$(r)"
            @test format_string("$(l)i for i$(sp)$(op)$(sp)I, j$(sp)$(op)$(sp)J if i < j$(r)") ==
                "$(l)i for i in I, j in J if i < j$(r)"
        end
    end
    # ∈ is still allowed when used as an operator outside of loop contexts in order to keep
    # symmetry with ∉ which doesn't have a direct ascii equivalent.
    # See https://github.com/fredrikekre/Runic.jl/issues/17
    @test format_string("a ∈ A") == "a ∈ A"
    @test format_string("a ∉ A") == "a ∉ A"
end

@testset "braces around where rhs" begin
    @test format_string("A where B") == "A where {B}"
    @test format_string("A where B <: C") == "A where {B <: C}"
    @test format_string("A where B >: C") == "A where {B >: C}"
    @test format_string("A where B where C") == "A where {B} where {C}"
end

@testset "block/hard indentation" begin
    for sp in ("", "  ", "    ", "      ")
        # function-end
        @test format_string("function f()\n$(sp)x\n$(sp)end") ==
            "function f()\n    return x\nend"
        @test format_string("function f end") == "function f end"
        @test_broken format_string("function f\nend") == "function f\nend" # TODO
        @test format_string("function ∉ end") == "function ∉ end"
        # macro-end
        @test format_string("macro f()\n$(sp)x\n$(sp)end") ==
            "macro f()\n    return x\nend"
        @test format_string("macro f() x end") == "macro f()\n    return x\nend"
        # let-end
        @test format_string("let a = 1\n$(sp)x\n$(sp)end") == "let a = 1\n    x\nend"
        @test format_string("let\n$(sp)x\n$(sp)end") == "let\n    x\nend"
        @test format_string("let a = 1 # a\n$(sp)x\n$(sp)end") ==
            "let a = 1 # a\n    x\nend"
        @test format_string("let a = 1; x end") == "let a = 1\n    x\nend"
        # begin-end
        @test format_string("begin\n$(sp)x\n$(sp)end") ==
            "begin\n    x\nend"
        # quote-end
        @test format_string("quote\n$(sp)x\n$(sp)end") ==
            "quote\n    x\nend"
        # if-end
        @test format_string("if a\n$(sp)x\n$(sp)end") ==
            "if a\n    x\nend"
        # if-else-end
        @test format_string("if a\n$(sp)x\n$(sp)else\n$(sp)y\n$(sp)end") ==
            "if a\n    x\nelse\n    y\nend"
        # if-elseif-end
        @test format_string("if a\n$(sp)x\n$(sp)elseif b\n$(sp)y\n$(sp)end") ==
            "if a\n    x\nelseif b\n    y\nend"
        # if-elseif-elseif-end
        @test format_string(
            "if a\n$(sp)x\n$(sp)elseif b\n$(sp)y\n$(sp)elseif c\n$(sp)z\n$(sp)end"
        ) == "if a\n    x\nelseif b\n    y\nelseif c\n    z\nend"
        # if-elseif-else-end
        @test format_string(
            "if a\n$(sp)x\n$(sp)elseif b\n$(sp)y\n$(sp)else\n$(sp)z\n$(sp)end"
        ) == "if a\n    x\nelseif b\n    y\nelse\n    z\nend"
        # if-elseif-elseif-else-end
        @test format_string(
            "if a\n$(sp)x\n$(sp)elseif b\n$(sp)y\n$(sp)elseif " *
                "c\n$(sp)z\n$(sp)else\n$(sp)u\n$(sp)end"
        ) == "if a\n    x\nelseif b\n    y\nelseif c\n    z\nelse\n    u\nend"
        # begin-end
        @test format_string("begin\n$(sp)x\n$(sp)end") == "begin\n    x\nend"
        # (mutable) struct
        for mut in ("", "mutable ")
            @test format_string("$(mut)struct A\n$(sp)x\n$(sp)end") ==
                "$(mut)struct A\n    x\nend"
        end
        # for-end
        @test format_string("for i in I\n$(sp)x\n$(sp)end") == "for i in I\n    x\nend"
        @test format_string("for i in I, j in J\n$(sp)x\n$(sp)end") == "for i in I, j in J\n    x\nend"
        # while-end
        @test format_string("while x\n$(sp)y\n$(sp)end") == "while x\n    y\nend"
        @test format_string("while (x = 1; x == 1)\n$(sp)y\n$(sp)end") ==
            "while (x = 1; x == 1)\n    y\nend"
        # try-catch-end
        @test format_string("try\n$(sp)x\n$(sp)catch\n$(sp)y\n$(sp)end") ==
            "try\n    x\ncatch\n    y\nend"
        # try-catch(err)-end
        @test format_string("try\n$(sp)x\n$(sp)catch err\n$(sp)y\n$(sp)end") ==
            "try\n    x\ncatch err\n    y\nend"
        # try-catch-finally-end
        @test format_string(
            "try\n$(sp)x\n$(sp)catch\n$(sp)y\n$(sp)finally\n$(sp)z\n$(sp)end"
        ) == "try\n    x\ncatch\n    y\nfinally\n    z\nend"
        # try-catch(err)-finally-end
        @test format_string(
            "try\n$(sp)x\n$(sp)catch err\n$(sp)y\n$(sp)finally\n$(sp)z\n$(sp)end"
        ) == "try\n    x\ncatch err\n    y\nfinally\n    z\nend"
        # try-finally-catch-end (yes, this is allowed...)
        @test format_string(
            "try\n$(sp)x\n$(sp)finally\n$(sp)y\n$(sp)catch\n$(sp)z\n$(sp)end"
        ) == "try\n    x\nfinally\n    y\ncatch\n    z\nend"
        # try-finally-catch(err)-end
        @test format_string(
            "try\n$(sp)x\n$(sp)finally\n$(sp)y\n$(sp)catch err\n$(sp)z\n$(sp)end"
        ) == "try\n    x\nfinally\n    y\ncatch err\n    z\nend"
        # try-catch-else-end
        @test format_string(
            "try\n$(sp)x\n$(sp)catch\n$(sp)y\n$(sp)else\n$(sp)z\n$(sp)end"
        ) == "try\n    x\ncatch\n    y\nelse\n    z\nend"
        # try-catch(err)-else-end
        @test format_string(
            "try\n$(sp)x\n$(sp)catch err\n$(sp)y\n$(sp)else\n$(sp)z\n$(sp)end"
        ) == "try\n    x\ncatch err\n    y\nelse\n    z\nend"
        # try-catch-else-finally-end
        @test format_string(
            "try\n$(sp)x\n$(sp)catch\n$(sp)y\n$(sp)else\n$(sp)z\n$(sp)finally\n$(sp)z\n$(sp)end"
        ) == "try\n    x\ncatch\n    y\nelse\n    z\nfinally\n    z\nend"
        # try-catch(err)-else-finally-end
        @test format_string(
            "try\n$(sp)x\n$(sp)catch err\n$(sp)y\n$(sp)else\n$(sp)z\n$(sp)finally\n$(sp)z\n$(sp)end"
        ) == "try\n    x\ncatch err\n    y\nelse\n    z\nfinally\n    z\nend"
        # do-end
        @test format_string("open() do\n$(sp)a\n$(sp)end") == "open() do\n    a\nend"
        @test format_string("open() do io\n$(sp)a\n$(sp)end") == "open() do io\n    a\nend"
        # module-end, baremodule-end
        for b in ("", "bare")
            # Just a module
            @test format_string("$(b)module A\n$(sp)x\n$(sp)end") == "$(b)module A\nx\nend"
            # Comment before
            @test format_string("# c\n$(b)module A\n$(sp)x\n$(sp)end") ==
                "# c\n$(b)module A\nx\nend"
            # Docstring before
            @test format_string("\"doc\"\n$(b)module A\n$(sp)x\n$(sp)end") ==
                "\"doc\"\n$(b)module A\nx\nend"
            # code before
            @test format_string("f\n$(b)module A\n$(sp)x\n$(sp)end") ==
                "f\n$(b)module A\n    x\nend"
            @test format_string("f\n$(b)module A\n$(sp)x\n$(sp)end\n$(b)module B\n$(sp)x\n$(sp)end") ==
                "f\n$(b)module A\n    x\nend\n$(b)module B\n    x\nend"
            # code after
            @test format_string("$(b)module A\n$(sp)x\n$(sp)end\nf") ==
                "$(b)module A\n    x\nend\nf"
            # nested modules
            @test format_string("$(b)module A\n$(sp)$(b)module B\n$(sp)x\n$(sp)end\n$(sp)end") ==
                "$(b)module A\n$(b)module B\n    x\nend\nend"
            # nested documented modules
            @test format_string("\"doc\"\n$(b)module A\n\"doc\"\n$(b)module B\n$(sp)x\n$(sp)end\n$(sp)end") ==
                "\"doc\"\n$(b)module A\n\"doc\"\n$(b)module B\n    x\nend\nend"
            # toplevel documented module with more things
            @test format_string("\"doc\"\n$(b)module A\n$(sp)x\nend\nf") ==
                "\"doc\"\n$(b)module A\n    x\nend\nf"
            # var"" as module name
            @test format_string("$(b)module var\"A\"\n$(sp)x\n$(sp)end\nf") ==
                "$(b)module var\"A\"\n    x\nend\nf"
            # interpolated module name
            @test format_string("$(b)module \$A\n$(sp)x\n$(sp)end\nf") ==
                "$(b)module \$A\n    x\nend\nf"
            # parenthesized module name (Why....)
            @test format_string("$(b)module$(sp)(A)\n$(sp)x\n$(sp)end\nf") ==
                "$(b)module (A)\n    x\nend\nf"
            @test format_string("$(b)module \$(A)\n$(sp)x\n$(sp)end\nf") ==
                "$(b)module \$(A)\n    x\nend\nf"
            # single line module
            @test format_string("$(b)module A; x; end\nf") == "$(b)module A;\n    x;\nend\nf"
        end
        # tuple
        @test format_string("(a,\n$(sp)b)") == "(\n    a,\n    b,\n)"
        @test format_string("(a,\n$(sp)b\n$(sp))") ==
            format_string("(a,\n$(sp)b,\n$(sp))") == "(\n    a,\n    b,\n)"
        @test format_string("(\n$(sp)a,\n$(sp)b,\n$(sp))") == "(\n    a,\n    b,\n)"
        # call, dotcall
        for sep in (",", ";"), d in ("", ".")
            @test format_string("f$(d)(a$(sep)\n$(sp)b)") == "f$(d)(\n    a$(sep)\n    b\n)"
            @test format_string("f$(d)(a$(sep)\n$(sp)b\n$(sp))") ==
                "f$(d)(\n    a$(sep)\n    b\n)"
            @test format_string("f$(d)(a$(sep)\n$(sp)b,\n$(sp))") ==
                format_string("f$(d)(\n$(sp)a$(sep)\n$(sp)b,\n$(sp))") ==
                "f$(d)(\n    a$(sep)\n    b,\n)"
        end
        # paren-quote
        @test format_string(":(a,\n$(sp)b)") == ":(\n    a,\n    b,\n)"
        @test format_string(":(a,\n$(sp)b)") == ":(\n    a,\n    b,\n)"
        @test format_string(":(a;\n$(sp)b)") == ":(\n    a;\n    b\n)"
        # paren-block
        @test format_string("(a;\n$(sp)b)") == "(\n    a;\n    b\n)"
        # curly, braces, bracescat
        for x in ("", "X")
            tr = x == "" ? "" : ","
            @test format_string("$(x){a,\n$(sp)b}") ==
                format_string("$(x){a,\n$(sp)b\n$(sp)}") ==
                format_string("$(x){a,\n$(sp)b,\n$(sp)}") ==
                format_string("$(x){\n$(sp)a,\n$(sp)b\n$(sp)}") ==
                format_string("$(x){\n$(sp)a,\n$(sp)b,\n$(sp)}") ==
                "$(x){\n    a,\n    b,\n}"
            @test format_string("$(x){a;\n$(sp)b\n$(sp)}") ==
                format_string("$(x){\n$(sp)a;\n$(sp)b\n$(sp)}") ==
                "$(x){\n    a;\n    b$(tr)\n}"
        end
        # array literals
        for t in ("", "T")
            @test format_string("$(t)[a,\n$(sp)b]") == "$(t)[\n    a,\n    b,\n]"
            @test format_string("$(t)[\n$(sp)a,\n$(sp)b\n$(sp)]") == "$(t)[\n    a,\n    b,\n]"
            @test format_string("$(t)[a b\n$(sp)c d]") == "$(t)[\n    a b\n    c d\n]"
            @test format_string("$(t)[\n$(sp)a b\n$(sp)c d\n$(sp)]") == "$(t)[\n    a b\n    c d\n]"
            # vcat
            @test format_string("$(t)[$(sp)a b;\nc d;$(sp)]") ==
                format_string("$(t)[\na b;\nc d;$(sp)]") ==
                format_string("$(t)[$(sp)a b;\nc d;\n]") ==
                format_string("$(t)[\na b;\nc d;\n]") == "$(t)[\n    a b;\n    c d;\n]"
        end
        # array comprehension
        for t in ("", "T")
            @test format_string("$(t)[$(sp)a for a in b$(sp)\n$(sp)]") ==
                format_string("$(t)[$(sp)\n$(sp)a for a in b$(sp)]") ==
                format_string("$(t)[$(sp)\n$(sp)a for a in b$(sp)\n$(sp)]") ==
                "$(t)[\n    a for a in b\n]"
        end
        # Single line begin-end
        @test format_string("begin x\n$(sp)end") == "begin\n    x\nend"
        @test format_string("begin x end") == "begin\n    x\nend"
        @test format_string("begin\n    x end") == "begin\n    x\nend"
        # Functors
        @test format_string("function$(sp)(a::A)(b)\nx\nend") ==
            "function (a::A)(b)\n    return x\nend"
        @test format_string("function$(sp)(a * b)\nreturn\nend") ==
            "function (a * b)\n    return\nend"
        # https://github.com/fredrikekre/Runic.jl/issues/109
        @test format_string("function$(sp)(::Type{T})(::Int) where {T}\n$(sp)return T\n$(sp)end") ==
            "function (::Type{T})(::Int) where {T}\n    return T\nend"
        @test format_string("function$(sp)()() end") == "function ()() end"
        # Multiline strings inside lists
        for trip in ("\"\"\"", "```")
            @test format_string("println(io, $(trip)\n$(sp)a\n$(sp)\n$(sp)b\n$(sp)$(trip))") ==
                "println(\n    io, $(trip)\n    a\n\n    b\n    $(trip)\n)"
            # Triple string on same line
            for b in ("", "\$b", "\$(b)", "\$(b)c")
                @test format_string("println(io, $(trip)a$b$(trip))") ==
                    "println(io, $(trip)a$b$(trip))"
            end
        end
    end
end

@testset "continuation/soft indentation" begin
    for sp in ("", "  ", "    ", "      ")
        # op-call, dot-op-call
        for d in ("", ".")
            @test format_string("a $(d)+\n$(sp)b") == "a $(d)+\n    b"
            @test format_string("a $(d)+ b $(d)*\n$(sp)c") == "a $(d)+ b $(d)*\n    c"
            @test format_string("a $(d)+\n$(sp)b $(d)*\n$(sp)c") == "a $(d)+\n    b $(d)*\n    c"
            @test format_string("a $(d)||\n$(sp)b") == "a $(d)||\n    b"
        end
        # assignment
        for nl in ("\n", "\n\n")
            # Regular line continuation of newlines between `=` and rhs
            for op in ("=", "+=", ".=", ".+=")
                @test format_string("a $(op)$(nl)b") == "a $(op)$(nl)    b"
                @test format_string("a $(op)$(nl)# comment$(nl)b") ==
                    "a $(op)$(nl)    # comment$(nl)    b"
            end
            @test format_string("f(a) =$(nl)b") == "f(a) =$(nl)    b"
            # Blocklike RHS
            for thing in (
                    "if c\n    x\nend", "try\n    x\ncatch\n    y\nend",
                    "let c = 1\n    c\nend", "function ()\n    return x\nend",
                    "\"\"\"\nfoo\n\"\"\"", "r\"\"\"\nfoo\n\"\"\"",
                    "```\nfoo\n```", "r```\nfoo\n```", "```\nfoo\n```x",
                )
                @test format_string("a =$(nl)$(thing)") == "a =$(nl)$(thing)"
                @test format_string("a =$(nl)# comment$(nl)$(thing)") ==
                    "a =$(nl)# comment$(nl)$(thing)"
                @test format_string("a = $(thing)") == "a = $(thing)"
                @test format_string("a = #=comment=#$(sp)$(thing)") ==
                    "a = #=comment=# $(thing)"
            end
        end
        # using/import
        for verb in ("using", "import")
            @test format_string("$(verb) A,\n$(sp)B") == "$(verb) A,\n    B"
            @test format_string("$(verb) A: a,\n$(sp)b") == "$(verb) A: a,\n    b"
            @test format_string("$(verb) A:\n$(sp)a,\n$(sp)b") == "$(verb) A:\n    a,\n    b"
        end
        # export/public/global/local
        for verb in ("export", "public", "global", "local"), b in ("b", "var\"b\"")
            @test format_string("$(verb) a,\n$(sp)$(b)") == "$(verb) a,\n    $(b)"
            @test format_string("$(verb)\n$(sp)a,\n$(sp)$(b)") == "$(verb)\n    a,\n    $(b)"
        end
        # ternary
        @test format_string("a ?\n$(sp)b : c") == "a ?\n    b : c"
        @test format_string("a ? b :\n$(sp)c") == "a ? b :\n    c"
        @test format_string("a ?\n$(sp)b :\n$(sp)c") == "a ?\n    b :\n    c"
        @test format_string("a ?\n$(sp)b :\n$(sp)c ?\n$(sp)d : e") ==
            "a ?\n    b :\n    c ?\n    d : e"
        @test format_string("(\n$(sp)a ? b : c,\n)") ==
            "(\n    a ? b : c,\n)"
        @test format_string("f(\n$(sp)a ? b : c,\n)") ==
            "f(\n    a ? b : c,\n)"
        @test format_string("f(\n$(sp)a ? b : c\n)") ==
            "f(\n    a ? b : c\n)"
        # comparison
        @test format_string("a == b ==\n$(sp)c") == "a == b ==\n    c"
        @test format_string("a <= b >=\n$(sp)c") == "a <= b >=\n    c"
        # implicit tuple
        @test format_string("a,\n$(sp)b") == "a,\n    b"
        @test format_string("a,\n$(sp)b + \nb") == "a,\n    b +\n    b"
        # implicit tuple in destructuring (LHS of K"=")
        @test format_string("a,$(sp)=$(sp)z") == "a, = z"
        @test format_string("a,$(sp)b$(sp)=$(sp)z") == "a, b = z"
        @test format_string("a,$(sp)b$(sp),$(sp)=$(sp)z") == "a, b, = z"
        # K"cartesian_iterator"
        @test format_string("for i in I,\n$(sp)j in J\n# body\nend") ==
            "for i in I,\n        j in J\n    # body\nend"
        # K"let"
        for a in ("x = 1", "x", "@inline foo() = 1", "\$x"),
                b in ("y = 1", "y", "@inline bar() = 1", "\$y")
            @test format_string("let $(a),\n$(sp)$(b)\n    nothing\nend") ==
                "let $(a),\n        $(b)\n    nothing\nend"
        end
    end
end

@testset "parens around op calls in colon" begin
    for a in ("a + a", "a + a * a"), sp in ("", " ", "  ")
        @test format_string("$(a)$(sp):$(sp)$(a)") == "($(a)):($(a))"
        @test format_string("$(a)$(sp):$(sp)$(a)$(sp):$(sp)$(a)") == "($(a)):($(a)):($(a))"
        @test format_string("$(a)$(sp):$(sp)$(a)$(sp):$(sp)$(a):$(a)") == "(($(a)):($(a)):($(a))):($(a))"
    end
    # No-ops
    for p in ("", "()"), sp in ("", " ", "  ")
        @test format_string("a$(p)$(sp):$(sp)b$(p)") == "a$(p):b$(p)"
        @test format_string("a$(p)$(sp):$(sp)b$(p)$(sp):$(sp)c$(p)") == "a$(p):b$(p):c$(p)"
    end
    # Edgecase: leading whitespace so that the paren have to be inserted in the middle of
    # the node
    Runic.format_string("i in a + b:c") == "i in (a + b):c"
end

@testset "leading and trailing newline in multiline listlike" begin
    for (o, c) in (("f(", ")"), ("@f(", ")"), ("(", ")"), ("{", "}"))
        tr = o in ("f(", "@f(") ? "" : ","
        @test format_string("$(o)a,\nb$(c)") ==
            format_string("$(o)\na,\nb$(c)") ==
            format_string("$(o)\na,\nb\n$(c)") ==
            "$(o)\n    a,\n    b$(tr)\n$(c)"
        @test format_string("$(o)a, # a\nb$(c)") ==
            format_string("$(o)\na, # a\nb$(c)") ==
            format_string("$(o)\na, # a\nb\n$(c)") ==
            "$(o)\n    a, # a\n    b$(tr)\n$(c)"
    end
end

@testset "max three consecutive newlines" begin
    f, g = "f() = 1", "g() = 2"
    for n in 1:5
        nl = "\n"
        m = min(n, 3)
        @test format_string(f * nl^n * g) == f * nl^m * g
        @test format_string("module A" * nl^n * "end") == "module A" * nl^m * "end"
        @test format_string("function f()" * nl^n * "end") == "function f()" * nl^m * "end"
        @test format_string("function f()" * nl^2 * "return x" * nl^n * "end") ==
            "function f()" * nl^2 * "    return x" * nl^m * "end"
    end
end

@testset "leading and trailing newlines in filemode" begin
    for n in 0:5
        nl = "\n"^n
        @test format_string("$(nl)f()$(nl)"; filemode = true) == "f()\n"
        @test format_string("$(nl)"; filemode = true) == "\n"
    end
    @test format_string(" x\n"; filemode = true) == "x\n"
end

@testset "https://youtu.be/SsoOG6ZeyUI?si=xpKpnczuqsOThtFP" begin
    @test format_string("f(a,\tb)") == "f(a, b)"
    @test format_string("begin\n\tx = 1\nend") == "begin\n    x = 1\nend"
end

@testset "spaces in using/import" begin
    for sp in ("", " ", "  ", "\t"), verb in ("using", "import")
        # Simple lists
        @test format_string("$(verb) $(sp)A") == "$(verb) A"
        @test format_string("$(verb)\nA") == "$(verb)\n    A"
        @test format_string("$(verb) $(sp)A$(sp),$(sp)B") == "$(verb) A, B"
        @test format_string("$(verb) A$(sp),\nB") == "$(verb) A,\n    B"
        @test format_string("$(verb) \nA$(sp),\nB") == "$(verb)\n    A,\n    B"
        @test format_string("$(verb) $(sp)A,$(sp)\n\n$(sp)B") == "$(verb) A,\n\n    B"
        # Colon lists
        for a in ("a", "@a", "*")
            @test format_string("$(verb) $(sp)A: $(sp)$(a)") == "$(verb) A: $(a)"
            for b in ("b", "@b", "*")
                @test format_string("$(verb) $(sp)A: $(sp)$(a)$(sp),$(sp)$(b)") ==
                    "$(verb) A: $(a), $(b)"
                @test format_string("$(verb) $(sp)A: $(sp)$(a)$(sp),\n$(b)") ==
                    "$(verb) A: $(a),\n    $(b)"
                @test format_string("$(verb) $(sp)A: $(sp)$(a)$(sp),$(sp)# c\n$(b)") ==
                    "$(verb) A: $(a), # c\n    $(b)"
            end
        end
    end
    for sp in ("", " ", "  ", "\t")
        # `import A as a, ...`
        @test format_string("import $(sp)A $(sp)as $(sp)a") == "import A as a"
        @test format_string("import $(sp)A $(sp)as $(sp)a$(sp),$(sp)B $(sp)as $(sp)b") ==
            "import A as a, B as b"
        @test format_string("import $(sp)A $(sp)as $(sp)a$(sp),$(sp)B") ==
            "import A as a, B"
        @test format_string("import $(sp)A$(sp),$(sp)B $(sp)as $(sp)b") ==
            "import A, B as b"
        # `(import|using) A: a as b, ...`
        for verb in ("using", "import")
            @test format_string("$(verb) $(sp)A: $(sp)a $(sp)as $(sp)b") == "$(verb) A: a as b"
            @test format_string("$(verb) $(sp)A: $(sp)a $(sp)as $(sp)b$(sp),$(sp)c $(sp)as $(sp)d") ==
                "$(verb) A: a as b, c as d"
            @test format_string("$(verb) $(sp)A: $(sp)a $(sp)as $(sp)b$(sp),$(sp)c") ==
                "$(verb) A: a as b, c"
            @test format_string("$(verb) $(sp)A: $(sp)a$(sp),$(sp)c $(sp)as $(sp)d") ==
                "$(verb) A: a, c as d"
        end
    end
    # Interpolated aliases in quotes and macrocalls
    @test format_string("quote\nimport A as \$a\nend") == "quote\n    import A as \$a\nend"
    @test format_string(":(import A as \$a)") == ":(import A as \$a)"
    @test format_string("@eval import A as \$a") == "@eval import A as \$a"
    # Macro-aliases
    @test format_string("import  A.@a  as  @b") == "import A.@a as @b"
end

@testset "spaces in export/public/global/local" begin
    for sp in ("", " ", "  ", "\t"), verb in ("export", "public", "global", "local"),
            (a, b) in (("a", "b"), ("a", "@b"), ("@a", "b"))
        if verb in ("global", "local") && (a, b) != ("a", "b")
            # global and local only support K"Identifier"s right now
            continue
        end
        @test format_string("$(verb) $(sp)$(a)") == "$(verb) $(a)"
        @test format_string("$(verb)\n$(a)") == "$(verb)\n    $(a)"
        @test format_string("$(verb) $(sp)$(a)$(sp),$(sp)$(b)") == "$(verb) $(a), $(b)"
        @test format_string("$(verb) $(a)$(sp),\n$(b)") == "$(verb) $(a),\n    $(b)"
        @test format_string("$(verb) \n$(a)$(sp),\n$(b)") == "$(verb)\n    $(a),\n    $(b)"
        @test format_string("$(verb) $(a)$(sp),\n# b\n$(b)") == "$(verb) $(a),\n    # b\n    $(b)"
        # Inline comments
        @test format_string("$(verb) a$(sp),$(sp)#= b, =#$(sp)c") == "$(verb) a, #= b, =# c"
        # https://github.com/fredrikekre/Runic.jl/issues/78
        @test format_string("$(verb)\n    #a\n    a,\n\n    #b\nb") == "$(verb)\n    #a\n    a,\n\n    #b\n    b"
        @test format_string("$(verb) $(sp)a,$(sp)\n\n$(sp)b") == "$(verb) a,\n\n    b"
    end
    # Interpolated identifiers (currently only expected in K"quote" and K"macrocall")
    @test format_string(":(export \$a)") == ":(export \$a)"
    @test format_string("quote\nexport \$a, \$b\nend") == "quote\n    export \$a, \$b\nend"
    @test format_string("@eval export \$a") == "@eval export \$a"
    @test_throws Exception format_string("export \$a")
    # Non-identifiers
    @test format_string("export ^, var\"x\"") == "export ^, var\"x\""
    # Parenthesized identifiers. JuliaSyntax gives a warning but it is still allowed.
    @test format_string("export (a) ,  (^)") == "export (a), (^)"
end

@testset "parsing new syntax" begin
    @test format_string("public a, b") == "public a, b" # Julia 1.11
end

@testset "indent of multiline strings" begin
    for triple in ("\"\"\"", "```"), sp in ("", " ", "    "),
            (pre, post) in (("", ""), ("pre", ""), ("pre", "post"))
        otriple = pre * triple
        ctriple = triple * post
        # Level 0
        @test format_string("$(sp)$(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)") ===
            "$(sp)$(otriple)\na\nb\n$(ctriple)"
        @test format_string("$(sp)$(otriple)\n$(sp)a\n\n$(sp)b\n$(sp)$(ctriple)") ===
            "$(sp)$(otriple)\na\n\nb\n$(ctriple)"
        @test format_string("x = $(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)") ===
            "x = $(otriple)\na\nb\n$(ctriple)"
        @test format_string("$(sp)$(otriple)a\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)") ===
            "$(sp)$(otriple)a\na\nb\n$(ctriple)"
        @test format_string("$(sp)$(otriple)\n$(sp)a\$(b)c\n$(sp)$(ctriple)") ===
            "$(sp)$(otriple)\na\$(b)c\n$(ctriple)"
        # Level 1
        @test format_string("begin\n$(sp)$(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)\nend") ===
            "begin\n    $(otriple)\n    a\n    b\n    $(ctriple)\nend"
        @test format_string("begin\n$(sp)$(otriple)\n$(sp)a\n$(sp)\n$(sp)b\n$(sp)$(ctriple)\nend") ===
            "begin\n    $(otriple)\n    a\n\n    b\n    $(ctriple)\nend"
        @test format_string("begin\n$(sp)x = $(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)\nend") ===
            "begin\n    x = $(otriple)\n    a\n    b\n    $(ctriple)\nend"
        @test format_string("begin\n$(sp)$(otriple)a\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)\nend") ===
            "begin\n    $(otriple)a\n    a\n    b\n    $(ctriple)\nend"
        @test format_string("begin\n$(sp)$(otriple)\n$(sp)a\$(b)c\n$(sp)$(ctriple)\nend") ===
            "begin\n    $(otriple)\n    a\$(b)c\n    $(ctriple)\nend"
        # Line continuation with `\`
        @test format_string("$(otriple)\n$(sp)a\\\n$(sp)b\n$(sp)$(ctriple)") ===
            "$(otriple)\na\\\nb\n$(ctriple)"
        @test format_string("begin\n$(otriple)\n$(sp)a\\\n$(sp)b\n$(sp)$(ctriple)\nend") ===
            "begin\n    $(otriple)\n    a\\\n    b\n    $(ctriple)\nend"
        # Triple strings with continuation indent
        @test format_string("x = $(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)") ===
            "x = $(otriple)\na\nb\n$(ctriple)"
        @test format_string("$(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple) * $(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)") ===
            "$(otriple)\na\nb\n$(ctriple) * $(otriple)\n    a\n    b\n    $(ctriple)"
        @test format_string("$(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple) *\n$(otriple)\n$(sp)a\n$(sp)b\n$(sp)$(ctriple)") ===
            "$(otriple)\na\nb\n$(ctriple) *\n    $(otriple)\n    a\n    b\n    $(ctriple)"
        # Implicit tuple
        @test format_string("$(otriple)\nabc\n$(ctriple), $(otriple)\ndef\n$(ctriple)") ===
            "$(otriple)\nabc\n$(ctriple), $(otriple)\n    def\n    $(ctriple)"
        @test format_string("$(otriple)\nabc\n$(ctriple),\n$(otriple)\ndef\n$(ctriple)") ===
            "$(otriple)\nabc\n$(ctriple),\n    $(otriple)\n    def\n    $(ctriple)"
        # Operator chains
        @test format_string("$(otriple)\nabc\n$(ctriple) * $(otriple)\ndef\n$(ctriple)") ===
            "$(otriple)\nabc\n$(ctriple) * $(otriple)\n    def\n    $(ctriple)"
        @test format_string("$(otriple)\nabc\n$(ctriple) *\n$(otriple)\ndef\n$(ctriple)") ===
            "$(otriple)\nabc\n$(ctriple) *\n    $(otriple)\n    def\n    $(ctriple)"
        @test format_string("x = $(otriple)\nabc\n$(ctriple) *\n$(otriple)\ndef\n$(ctriple)") ===
            "x = $(otriple)\n    abc\n    $(ctriple) *\n    $(otriple)\n    def\n    $(ctriple)"
        @test format_string("x = $(otriple)\nabc\n$(ctriple) *\n\"def\"") ===
            "x = $(otriple)\n    abc\n    $(ctriple) *\n    \"def\""
        @test format_string("x = \"abc\" *\n$(otriple)\ndef\n$(ctriple)") ===
            "x = \"abc\" *\n    $(otriple)\n    def\n    $(ctriple)"
    end
end

@testset "blocks start and end with newline" begin
    for d in (" ", ";", " ;", " ;", " ; ")
        # for/while-end
        for verb in ("for", "while")
            @test format_string("$(verb) x in X$(d)x$(d)end") ==
                format_string("$(verb) x in X$(d)\nx end") ==
                format_string("$(verb) x in X$(d)x\nend") ==
                "$(verb) x in X\n    x\nend"
        end
        # if-end
        @test format_string("if a$(d)x$(d)end") == "if a\n    x\nend"
        # if-else-end
        @test format_string("if a$(d)x$(d)else$(d)y$(d)end") == "if a\n    x\nelse\n    y\nend"
        # if-elseif-end
        @test format_string("if a$(d)x$(d)elseif b$(d)y$(d)end") == "if a\n    x\nelseif b\n    y\nend"
        # if-elseif-elseif-end
        @test format_string("if a$(d)x$(d)elseif b$(d)y$(d)elseif c$(d)z$(d)end") ==
            "if a\n    x\nelseif b\n    y\nelseif c\n    z\nend"
        # if-elseif-else-end
        @test format_string("if a$(d)x$(d)elseif b$(d)y$(d)else$(d)z$(d)end") ==
            "if a\n    x\nelseif b\n    y\nelse\n    z\nend"
        # if-elseif-elseif-else-end
        @test format_string("if a$(d)x$(d)elseif b$(d)y$(d)elseif c$(d)z$(d)else$(d)u$(d)end") ==
            "if a\n    x\nelseif b\n    y\nelseif c\n    z\nelse\n    u\nend"
        # try-catch-end
        @test format_string("try$(d)x$(d)catch\ny$(d)end") == "try\n    x\ncatch\n    y\nend"
        # try-catch(err)-end
        @test format_string("try$(d)x$(d)catch err$(d)y$(d)end") == "try\n    x\ncatch err\n    y\nend"
        # try-catch-finally-end
        @test format_string("try$(d)x$(d)catch\ny$(d)finally$(d)z$(d)end") ==
            "try\n    x\ncatch\n    y\nfinally\n    z\nend"
        # try-catch(err)-finally-end
        @test format_string("try$(d)x$(d)catch err$(d)y$(d)finally$(d)z$(d)end") ==
            "try\n    x\ncatch err\n    y\nfinally\n    z\nend"
        # try-finally-catch-end (yes, this is allowed...)
        @test format_string("try$(d)x$(d)finally$(d)y$(d)catch\nz$(d)end") ==
            "try\n    x\nfinally\n    y\ncatch\n    z\nend"
        # try-finally-catch(err)-end
        @test format_string("try$(d)x$(d)finally$(d)y$(d)catch err$(d)z$(d)end") ==
            "try\n    x\nfinally\n    y\ncatch err\n    z\nend"
        # try-catch-else-end
        @test format_string("try$(d)x$(d)catch\ny$(d)else$(d)z$(d)end") ==
            "try\n    x\ncatch\n    y\nelse\n    z\nend"
        # try-catch(err)-else-end
        @test format_string("try$(d)x$(d)catch err$(d)y$(d)else$(d)z$(d)end") ==
            "try\n    x\ncatch err\n    y\nelse\n    z\nend"
        # try-catch-else-finally-end
        @test format_string("try$(d)x$(d)catch\ny$(d)else$(d)z$(d)finally$(d)z$(d)end") ==
            "try\n    x\ncatch\n    y\nelse\n    z\nfinally\n    z\nend"
        # try-catch(err)-else-finally-end
        @test format_string("try$(d)x$(d)catch err$(d)y$(d)else$(d)z$(d)finally$(d)z$(d)end") ==
            "try\n    x\ncatch err\n    y\nelse\n    z\nfinally\n    z\nend"
        # do-end
        @test format_string("open() do\na$(d)end") == "open() do\n    a\nend"
        @test format_string("open() do\nend") == "open() do\nend"
        @test_broken format_string("open() do;a$(d)end") == "open() do\n    a\nend"
        @test_broken format_string("open() do ;a$(d)end") == "open() do\n    a\nend"
        @test format_string("open() do io$(d)a end") == "open() do io\n    a\nend"
        # let-end
        @test format_string("let a = 1\nx$(d)end") == "let a = 1\n    x\nend"
        @test format_string("let\nx$(d)end") == "let\n    x\nend"
        @test format_string("let a = 1 # a\nx$(d)end") == "let a = 1 # a\n    x\nend"
        # function-end
        @test format_string("function f()$(d)x$(d)end") == "function f()\n    return x\nend"
        @test format_string("function()$(d)x$(d)end") == "function ()\n    return x\nend"
        @test format_string("function ()$(d)x$(d)end") == "function ()\n    return x\nend"
        @test format_string("function f end") == "function f end"
        # macro-end
        @test format_string("macro f()$(d)x$(d)end") == "macro f()\n    return x\nend"
        # quote-end
        @test format_string("quote$(d)x$(d)end") == "quote\n    x\nend"
        # begin-end
        @test format_string("begin$(d)x$(d)end") == "begin\n    x\nend"
        # (mutable) struct
        for mut in ("", "mutable ")
            @test format_string("$(mut)struct A$(d)x$(d)end") == "$(mut)struct A\n    x\nend"
        end
        # https://github.com/fredrikekre/Runic.jl/issues/79
        @test format_string("while true$(d)x += 1\nend") == "while true\n    x += 1\nend"
    end # d-loop
    # module-end, baremodule-end
    for b in ("", "bare")
        # Just a module
        @test format_string("$(b)module A x end") == "$(b)module A\nx\nend"
        # Comment before
        @test format_string("# c\n$(b)module A x end") == "# c\n$(b)module A\nx\nend"
        # Docstring before
        @test format_string("\"doc\"\n$(b)module A x end") == "\"doc\"\n$(b)module A\nx\nend"
        # code before
        @test format_string("f\n$(b)module A x end") == "f\n$(b)module A\n    x\nend"
        @test format_string("f\n$(b)module A x end\n$(b)module B x end") ==
            "f\n$(b)module A\n    x\nend\n$(b)module B\n    x\nend"
        # code after
        @test format_string("$(b)module A x end\nf") == "$(b)module A\n    x\nend\nf"
        # nested modules
        @test format_string("$(b)module A $(b)module B x end end") ==
            "$(b)module A\n$(b)module B\n    x\nend\nend"
        # nested documented modules
        @test format_string("\"doc\"\n$(b)module A\n\"doc\"\n$(b)module B x end\nend") ==
            "\"doc\"\n$(b)module A\n\"doc\"\n$(b)module B\n    x\nend\nend"
    end
    # Empty blocks
    for verb in ("for", "while")
        @test format_string("$(verb) x in X end") == "$(verb) x in X end"
        @test format_string("$(verb) x in X\nend") == "$(verb) x in X\nend"
    end
    @test format_string("if a end") == "if a end"
    @test format_string("if a\nend") == "if a\nend"
    @test format_string("if a else end") == "if a else end"
    @test_broken format_string("if a x else end") == "if a\n    x\nelse\nend"
    @test format_string("if a elseif b end") == "if a elseif b end"
    @test_broken format_string("if a x elseif b end") == "if a\n    x\nelseif b\nend"
    @test format_string("if a elseif b elseif c end") == "if a elseif b elseif c end"
    @test_broken format_string("if a x elseif b elseif c end") ==
        "if a\n    x\nelseif b\nelseif c\nend"
    @test format_string("if a elseif b else end") == "if a elseif b else end"
    @test_broken format_string("if a x elseif b else end") == "if a\n    x\nelseif b\nelse\nend"
    @test format_string("if a elseif b elseif c else end") ==
        "if a elseif b elseif c else end"
    @test_broken format_string("if a elseif b elseif c else x end") ==
        "if a\nelseif b\nelseif c\nelse\n    x\nend"
    @test format_string("try catch y end") == "try catch y end"
    @test_broken format_string("try catch y y end") == "try\ncatch y\n    y\nend"
    @test format_string("open() do io end") == "open() do io end"
    @test format_string("function f() end") == "function f() end"
    @test format_string("macro f() end") == "macro f() end"
    @test format_string("quote end") == "quote end"
    @test format_string("begin end") == "begin end"
    for mut in ("", "mutable ")
        @test format_string("$(mut)struct A end") == "$(mut)struct A end"
    end
    for b in ("", "bare")
        @test format_string("$(b)module A end") == "$(b)module A end"
        @test format_string("$(b)module A $(b)module B end end") ==
            "$(b)module A\n$(b)module B end\nend"
    end
end

@testset "trailing semicolon" begin
    body = """
        # Semicolons on their own lines
        ;
        ;;
        # Trailing semicolon
        a;
        a;;
        # Trailing semicolon with ws after
        b; 
        b;; 
        # Trailing semicolon with ws before
        c ;
        c ;;
        # Trailing semicolon with ws before and after
        d ; 
        d ;; 
        # Trailing semicolon before comment
        e;# comment
        e;;# comment
        # Trailing semicolon before ws+comment
        f; # comment
        f;; # comment
        # Trailing semicolon with whitespace on both sides
        g ; # comment
    """
    bodyfmt = """
        # Semicolons on their own lines


        # Trailing semicolon
        a
        a
        # Trailing semicolon with ws after
        b
        b
        # Trailing semicolon with ws before
        c
        c
        # Trailing semicolon with ws before and after
        d
        d
        # Trailing semicolon before comment
        e # comment
        e  # comment
        # Trailing semicolon before ws+comment
        f  # comment
        f   # comment
        # Trailing semicolon with whitespace on both sides
        g   # comment
    """
    for prefix in (
            "begin", "quote", "for i in I", "let", "let x = 1", "while cond",
            "if cond", "macro f()", "function f()", "f() do", "f() do x",
        )
        rx = prefix in ("function f()", "macro f()") ? "    return x\n" : ""
        @test format_string("$(prefix)\n$(body)$(rx)\nend") == "$prefix\n$(bodyfmt)$(rx)\nend"
    end
    @test format_string(
        "if cond1\n$(body)\nelseif cond2\n$(body)\nelseif cond3\n$(body)\nelse\n$(body)\nend"
    ) ==
        "if cond1\n$(bodyfmt)\nelseif cond2\n$(bodyfmt)\nelseif cond3\n$(bodyfmt)\nelse\n$(bodyfmt)\nend"
    @test format_string("try\n$(body)\ncatch\n$(body)\nend") ==
        "try\n$(bodyfmt)\ncatch\n$(bodyfmt)\nend"
    @test format_string("try\n$(body)\ncatch err\n$(body)\nend") ==
        "try\n$(bodyfmt)\ncatch err\n$(bodyfmt)\nend"
    @test format_string("try\n$(body)\nfinally\n$(body)\nend") ==
        "try\n$(bodyfmt)\nfinally\n$(bodyfmt)\nend"
    @test format_string("try\n$(body)\ncatch\n$(body)\nfinally\n$(body)\nend") ==
        format_string("try\n$(bodyfmt)\ncatch\n$(bodyfmt)\nfinally\n$(bodyfmt)\nend")
    @test format_string("try\n$(body)\ncatch err\n$(body)\nfinally\n$(body)\nend") ==
        format_string("try\n$(bodyfmt)\ncatch err\n$(bodyfmt)\nfinally\n$(bodyfmt)\nend")
    @test format_string("try\n$(body)\ncatch err\n$(body)\nelse\n$(body)\nend") ==
        format_string("try\n$(bodyfmt)\ncatch err\n$(bodyfmt)\nelse\n$(bodyfmt)\nend")
    for mut in ("", "mutable ")
        @test format_string("$(mut)struct A\na::Int;\nend") ==
            "$(mut)struct A\n    a::Int\nend"
    end
    # Paren-blocks should be skipped
    @test format_string("if (a;\nb)\nend") == "if (\n        a;\n        b\n    )\nend"
    @test format_string("if begin a;\nb; end\nend") == "if begin\n        a\n        b\n    end\nend"
    # Top-level semicolons are kept (useful if you want to supress output in various
    # contexts)
    let str = """
        f(x) = 1;
        module A
            g(x) = 2;
        end;
        """
        @test format_string(str) == str
    end
end

@testset "explicit return" begin
    for f in ("function f()", "function ()", "macro m()")
        # Simple cases just prepend `return`
        for r in (
                "x", "*", "x, y", "(x, y)", "f()", "[1, 2]", "Int[1, 2]", "[1 2]", "Int[1 2]",
                "[1 2; 3 4]", "Int[1 2; 3 4]", "x ? y : z", "x && y", "x || y", ":x", ":(x)",
                ":(x; y)", "1 + 2", "f.(x)", "x .+ y", "x::Int", "2x", "T <: Integer",
                "T >: Int", "Int <: T <: Integer", "x < y > z", "\"foo\"", "\"\"\"foo\"\"\"",
                "a.b", "a.b.c", "x -> x^2", "[x for x in X]", "Int[x for x in X]",
                "A{T} where {T}", "(@m a, b)", "A{T}",
                "r\"foo\"", "r\"foo\"m", "`foo`", "```foo```", "r`foo`",
                "f() do\n        x\n    end", "f() do x\n        x\n    end",
                "function f()\n        return x\n    end",
                "function ()\n        return x\n    end",
                "quote\n        x\n    end", "begin\n        x\n    end",
                "let\n        x\n    end", "let x = 42\n        x\n    end",
                "x = 1", "x += 1", "x -= 1", "global x = 1", "local x = 1",
                "@inbounds x[i]", "@inline f(x)",
                "if c\n        x\n    end",
                "if c\n        x\n    else\n        y\n    end",
                "if c\n        x\n    elseif d\n        z\n    else\n        y\n    end",
                "try\n        x\n    catch\n        y\n    end",
                "try\n        x\n    catch e\n        y\n    end",
                "try\n        x\n    catch\n        y\n    finally\n        z\n    end",
                "try\n        x\n    catch\n        y\n    else\n        z\n    finally\n        z\n    end",
            )
            @test format_string("$f\n    $r\nend") == "$f\n    return $r\nend"
            @test format_string("$f\n    x;$r\nend") == "$f\n    x\n    return $r\nend"
            @test format_string("$f\n    x; $r\nend") == "$f\n    x\n    return $r\nend"
            # Nesting
            @test format_string("$f\n    $f\n        $r\n    end\nend") ==
                format_string("$f\n    return $f\n        return $r\n    end\nend")
        end
        # If the last expression is a call and the function name contains throw or error
        # there should be no return
        for r in ("throw(ArgumentError())", "error(\"foo\")", "rethrow()", "throw_error()")
            @test format_string("$f\n    $r\nend") == "$f\n    $r\nend"
        end
        # If the last expression is a macro call with return inside there should be no
        # return on the outside
        for r in (
                "@inbounds return x[i]", "@inbounds @inline return x[i]",
                "@inbounds begin\n        return x[i]\n    end",
            )
            @test format_string("$f\n    $r\nend") == "$f\n    $r\nend"
        end
        # Safe/known macros
        @test format_string("@inline $f\n    x\nend") ==
            "@inline $f\n    return x\nend"
        @test format_string("Base.@noinline $f\n    x\nend") ==
            "Base.@noinline $f\n    return x\nend"
        # Unsafe/unknown macros
        @test format_string("@kernel $f\n    x\nend") == "@kernel $f\n    x\nend"
        # `for` and `while` append `return` to the end
        for r in ("for i in I\n    end", "while i in I\n    end")
            @test format_string("$f\n    $r\nend") == "$f\n    $r\n    return\nend"
            @test format_string("$f\n    $r\n    # comment\nend") ==
                "$f\n    $r\n    # comment\n    return\nend"
        end
        # If there already is a `return` anywhere (not necessarily the last expression)
        # there will be no additional `return` added on the last expression.
        # `for` and `while` append `return` to the end
        let str = "$f\n    return 42\n    1337\nend"
            @test format_string(str) == str
        end
        # if/let/begin/try with a `return` inside should be left alone
        for r in (
                "if c\n        return x\n    end",
                "if c\n        return x\n    else\n        y\n    end",
                "if c\n        x\n    else\n        return y\n    end",
                "if c\n        return x\n    elseif d\n        y\n    else\n        y\n    end",
                "if c\n        x\n    elseif d\n        return y\n    else\n        z\n    end",
                "if c\n        x\n    elseif d\n        y\n    else\n        return z\n    end",
                "let\n        return x\n    end",
                "let x = 1\n        return x\n    end",
                "begin\n        return x\n    end",
                "try\n        return x\n    catch\n        y\n    end",
                "try\n        x\n    catch e\n        return y\n    end",
                "try\n        x\n    catch\n        y\n    finally\n        return z\n    end",
                "try\n        x\n    catch\n        y\n    else\n        return z\n    finally\n        z\n    end",
            )
            str = "$f\n    $r\nend"
            @test format_string(str) == str
        end
    end
end

@testset "# runic: (on|off)" begin
    for exc in ("", "!"), word in ("runic", "format")
        on = "#$(exc) $(word): on"
        off = "#$(exc) $(word): off"
        bon = "#$(exc == "" ? "!" : "") $(word): on"
        # Disable rest of the file from top level comment
        @test format_string("$off\n1+1") == "$off\n1+1"
        @test format_string("1+1\n$off\n1+1") == "1 + 1\n$off\n1+1"
        @test format_string("1+1\n$off\n1+1\n$on\n1+1") == "1 + 1\n$off\n1+1\n$on\n1 + 1"
        @test format_string("1+1\n$off\n1+1\n$bon\n1+1") == "1 + 1\n$off\n1+1\n$bon\n1+1"
        # Toggle inside a function
        @test format_string(
            """
            function f()
                $off
                1+1
                $on
                1+1
                return
            end
            """
        ) == """
            function f()
                $off
                1+1
                $on
                1 + 1
                return
            end
            """
        @test format_string(
            """
            function f()
                $off
                1+1
                $bon
                1+1
                return
            end
            """
        ) == """
            function f()
                $off
                1 + 1
                $bon
                1 + 1
                return
            end
            """
        @test format_string(
            """
            function f()
                $off
                1+1
                1+1
                return
            end
            """
        ) == """
            function f()
                $off
                1 + 1
                1 + 1
                return
            end
            """
        # Extra stuff in the toggle comments
        @test format_string("1+1\n$off #src\n1+1\n$on #src\n1+1") ==
            "1 + 1\n$off #src\n1+1\n$on #src\n1 + 1"
        @test format_string("1+1\n#src $off\n1+1\n#src $on\n1+1") ==
            "1 + 1\n#src $off\n1+1\n#src $on\n1 + 1"
        # Toggles inside literal array expression (fixed by normalization, PR #101)
        let str = """
            [
                $off
                 1.10  1.20  1.30
                -2.10 -1.20 +1.30
                f( a+b )
                $on
            ]"""
            @test format_string(str) == str
        end
    end
end

# TODO: Support lines in format_string and format_file
function format_lines(str, lines)
    line_ranges = lines isa UnitRange ? [lines] : lines
    ctx = Runic.Context(str; filemode = false, line_ranges = line_ranges)
    Runic.format_tree!(ctx)
    return String(take!(ctx.fmt_io))
end

@testset "--lines" begin
    str = """
    function f(a,b)
        return a+b
     end
    """
    @test format_lines(str, 1:1) == """
        function f(a, b)
            return a+b
         end
        """
    @test format_lines(str, 2:2) == """
        function f(a,b)
            return a + b
         end
        """
    @test format_lines(str, 3:3) == """
        function f(a,b)
            return a+b
        end
        """
    @test format_lines(str, [1:1, 3:3]) == """
        function f(a, b)
            return a+b
        end
        """
    @test format_lines(str, [1:1, 2:2, 3:3]) == """
        function f(a, b)
            return a + b
        end
        """
    @test format_lines(str, [1:2]) == """
        function f(a, b)
            return a + b
         end
        """
    @test format_lines(str, [2:4]) == """
        function f(a,b)
            return a + b
        end
        """
    @test format_lines(str, [4:4]) == str
    @test_throws Runic.MainError format_lines("1+1", [1:2])
end

module RunicMain1
    using Test: @testset
    using Runic: main
    include("maintests.jl")
    @testset "Runic.main (JIT compiled)" begin
        maintests(main)
    end
end

module RunicMain2
    using Test: @testset, @test
    if VERSION > v"1.12-"
        include("../juliac/runicc.jl")
        include("maintests.jl")
        function juliac_main(argv)
            pushfirst!(argv, "runic")
            juliac_main = @cfunction(RunicC.main, Cint, (Cint, Ptr{Ptr{UInt8}}))
            return @ccall $juliac_main(length(argv)::Cint, argv::Ptr{Ptr{UInt8}})::Cint
        end
        @testset "RunicC.main (JIT compiled, prefs: juliac = false)" begin
            @test !Runic.juliac
            maintests(juliac_main)
        end
    end
end

module RunicMain3
    if VERSION > v"1.12-"
        julia_cmd = Base.julia_cmd()
        juliac_dir = joinpath(@__DIR__, "..", "juliac")
        # Instantiate
        run(
            addenv(
                setenv(`make JULIA=$(julia_cmd[1]) Manifest.toml`; dir = juliac_dir),
                "JULIA_LOAD_PATH" => nothing,
                "JULIA_PROJECT" => nothing,
            )
        )
        # Run tests
        code = """
        using Test: @testset, @test
        include("runicc.jl")
        include("../test/maintests.jl")
        function juliac_main(argv)
            pushfirst!(argv, "runic")
            juliac_main = @cfunction(RunicC.main, Cint, (Cint, Ptr{Ptr{UInt8}}))
            @ccall \$juliac_main(length(argv)::Cint, argv::Ptr{Ptr{UInt8}})::Cint
        end
        @testset "RunicC.main (JIT compiled, prefs: juliac = true)" begin
            @test Runic.juliac
            maintests(juliac_main)
        end
        """
        run(setenv(`$(julia_cmd) --project -e $(code)`; dir = juliac_dir))
    end
end

const share_julia = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
if Sys.isunix() && isdir(share_julia)
    @testset "JuliaLang/julia" begin
        for testfolder in joinpath.(share_julia, ("base", "test"))
            for (root, _, files) in walkdir(testfolder)
                for file in files
                    endswith(file, ".jl") || continue
                    path = joinpath(root, file)
                    try
                        Runic.format_file(path, "/dev/null")
                        @test true
                    catch err
                        if err isa JuliaSyntax.ParseError
                            @warn "JuliaSyntax.ParseError for $path" err
                            @test_broken false
                        else
                            @error "Error when formatting file $path" err
                            @test false
                        end
                    end
                end
            end
        end
    end
end
