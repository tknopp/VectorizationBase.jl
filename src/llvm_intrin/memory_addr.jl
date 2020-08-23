"""
A - Unrolled axis
F - Factor, step size per unroll
N - How many times is it unrolled
M - bitmask indicating whether each factor is masked
i::I - index
"""
struct Unroll{A,F,N,I,M}
    i::I
end

"""
O - An `NTuple{M,NTuple{N,Int}}` tuple of tuples, specifies offsets of `N`-dim array for each of `M` loads.
u::U - the base unrolled description.
"""
struct MultiLoad{O,A,U,M,I}
    u::Unroll{U,V,F,W,M}
end

const SCOPE_METADATA = """
!1 = !{!\"noaliasdomain\"}
!2 = !{!\"noaliasscope\", !1}
!3 = !{!2}
"""
const LOAD_SCOPE_TBAA = SCOPE_METADATA * """
!4 = !{!"jtbaa"}
!5 = !{!6, !6, i64 0, i64 0}
!6 = !{!"jtbaa_arraybuf", !4, i64 0}
"""
const STORE_TBAA = """
!4 = !{!"jtbaa", !5, i64 0}
!5 = !{!"jtbaa"}
!6 = !{!"jtbaa_data", !4, i64 0}
!7 = !{!8, !8, i64 0}
!8 = !{!"jtbaa_arraybuf", !6, i64 0}
"""

function offset_ptr(::Type{T}, ::Type{I}, W::Int = 1, ivec::Bool = false, constmul::Int = 1, argind = '1', forgep::Bool = false) where {T <: NativeTypes, I <: Integer}
    ityp = vtype(ivec ? W : 1, 'i' * string(8sizeof(I)))
    typ = LLVM_TYPE[T]
    vtyp = vtype(W, typ)
    instrs = String[]
    if iszero(constmul)
        push!(instrs, "%ptr = inttoptr $JULIAPOINTERTYPE %0 to $vtyp*")
    else
        tz = min(trailing_zeros(constmul), 3)
        bits = 8 << tz
        ptyp = bits == 8sizeof(T) ? typ : 'i' * string(bits)
        desttyp = ivec ? typ : vtyp
        iptr = desttyp === ptyp ? "ptr" : "iptr"
        constmul >>= tz
        push!(instrs, "%typptr = inttoptr $JULIAPOINTERTYPE %0 to $ptyp*")
        if isone(constmul)
            push!(instrs, "%$(iptr) = getelementptr inbounds $ptyp, $ptyp* %typptr, $ityp %$(argind)")
        else
            cm = llvmconst(W, I, constmul)
            push!(instrs, """%ioff = mul nsw $ityp %$(argind), $cm
            %$(iptr) = getelementptr inbounds $ptyp, $ptyp* %typptr, $ityp %ioff""")
        end
        if ivec
            if ptyp !== typ
                if forgep
                    push!(instrs, "%ptr = ptrtoint <$W x $ptyp*> %iptr to <$W x $JULIAPOINTERTYPE>")
                else
                    push!(instrs, "%ptr = bitcast <$W x $ptyp*> %iptr to <$W x $typ*>")
                end
            end
        elseif ptyp !== vtyp
            if forgep
                push!(instrs, "%ptr = ptrtoint $ptyp* %iptr to $JULIAPOINTERTYPE")
            else
                push!(instrs, "%ptr = bitcast $ptyp* %iptr to $vtyp*")
            end
        end
    end
    instrs
end

function gep_quote(::Type{T}, ::Type{I}, W::Int = 1, ivec::Bool = false, constmul::Int = 1) where {T <: NativeTypes, I <: Integer}
    iszero(constmul) && return Expr(:block, Expr(:meta, :inline), :ptr)
    instrs = offset_ptr(T, I, W, ivec, constmul, '1', true)
    ret = Expr(:curly, :Ptr, T)
    lret = JULIAPOINTERTYPE
    args = Expr(:curly, :Tuple, Expr(:curly, :Ptr, T))
    largs = String[JULIAPOINTERTYPE]
    arg_syms = Union{Symbol,Expr}[:ptr, Expr(:call, :data, :i)]
    if ivec && W > 1
        ret = Expr(:curly, :NTuple, W, Expr(:curly, :VecElement, ret))
        lret = "<$W x $lret>"
        push!(args.args, Expr(:curly, :NTuple, W, Expr(:curly, :VecElement, I)))
        push!(largs, "<$W x i$(8sizeof(I))>")
    else
        push!(args.args, I)
        push!(largs, "i$(8sizeof(I))")
    end
    push!(instrs, "ret $lret %ptr")
    llvmcall_expr("", join(instrs, "\n"), ret, args, lret, largs, arg_syms)
end

@generated function gep(ptr::Ptr{T}, i::I) where {T <: NativeTypes, I <: Integer}
    gep_quote(T, I, 1, false, 1)
end
@generated function gep(ptr::Ptr{T}, i::LazyMul{N,I}) where {T <: NativeTypes, I <: Integer, N}
    gep_quote(T, I, 1, false, N)
end
# @generated function gep(ptr::Ptr{T}, i::Vec{I,W}) where {W, T <: NativeTypes, I <: Integer}
#     gep_quote(T, I, W, true, 1)
# end

function vload_quote(::Type{T}, ::Type{I}, W::Int = 1, ivec::Bool = false, mask::Bool = false, constmul::Int = 1) where {T <: NativeTypes, I <: Integer}
    ityp = vtype(ivec ? W : 1, 'i' * string(8sizeof(I)))
    typ = LLVM_TYPE[T]
    lret = vtyp = vtype(W, typ)
    decl = LOAD_SCOPE_TBAA
    alignment = Base.datatype_alignment(T)
    instrs = offset_ptr(T, I, W, ivec, constmul, '1')
    mask && truncate_mask!(instrs, ivec ? '2' : '1', W, min(8, W), 0)
    if ivec
        loadinstr = "$vtyp @llvm.masked.gather." * suffix(W, T) * '.' * suffix(W, Ptr{T})
        decl *= "declare $loadinstr(<$W x $typ*>, i32, <$W x i1>, $vtyp)"
        m = mask ? m = "mask.0" : llvmconst(W, "i1 1")
        # passthrough = mask ? "zeroinitializer" : "undef"
        push!(instrs, "%res = call $loadinstr(<$W x $typ*> %ptr, i32 $alignment, <$W x i1> %$m, $vtyp undef), !alias.scope !3, !tbaa !5")
    else
        if mask
            suff = suffix(W, T)
            loadinstr = "$vtyp @llvm.masked.load." * suff * ".p0" * suff
            decl *= "declare $loadinstr($vtyp*, i32, <$W x i1>, $vtyp)"
            push!(instrs, "%res = call $loadinstr($vtyp* %ptr, i32 $alignment, <$W x i1> %mask.0, $vtyp undef), !alias.scope !3, !tbaa !5")
        else
            push!(instrs, "%res = load $vtyp, $vtyp* %ptr, align $alignment, !alias.scope !3, !tbaa !5")
        end
    end
    push!(instrs, "ret $vtyp %res")
    ret = isone(W) ? T : Expr(:curly, :NTuple, W, Expr(:curly, :VecElement, T))
    args = Expr(:curly, :Tuple, Expr(:curly, :Ptr, T))
    largs = String[JULIAPOINTERTYPE]
    arg_syms = Union{Symbol,Expr}[:ptr]
    if !iszero(constmul)
        push!(arg_syms, Expr(:call, :data, :i))
        push!(largs, ityp)
        if ivec & (W > 1)
            push!(args.args, Expr(:curly, :NTuple, W, Expr(:curly, :VecElement, I)))
        else
            push!(args.args, I)
        end
    end
    if mask
        push!(arg_syms, Expr(:call, :data, :m))
        push!(largs, 'i'*string(max(8,W)))
        for (B,U) ∈ [(8,:UInt8),(16,:UInt16),(32,:UInt32),(64,:UInt64)]
            if W ≤ B
                push!(args.args, U)
                break
            end
        end
    end
    llvmcall_expr(decl, join(instrs, "\n"), ret, args, lret, largs, arg_syms)
end

@generated function vload(ptr::Ptr{T}) where {T <: NativeTypes}
    vload_quote(T, Int, 1, false, false, 0)
end
@generated function vload(ptr::Ptr{T}, i::I) where {T <: NativeTypes, I <: Integer}
    vload_quote(T, I, 1, false, false, 1)
end
@generated function vload(ptr::Ptr{T}, i::Vec{W,I}) where {W, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, true, false, 1)
end
@generated function vload(ptr::Ptr{T}, i::MM{W,I}) where {W, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, false, false, 1)
end
@generated function vload(ptr::Ptr{T}, i::Vec{W,I}, m::Mask{W}) where {W, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, true, true, 1)
end
@generated function vload(ptr::Ptr{T}, i::MM{W,I}, m::Mask{W}) where {W, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, false, true, 1)
end
@generated function vload(ptr::Ptr{T}, i::LazyMul{N,I}) where {N, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, 1, false, false, N)
end
@generated function vload(ptr::Ptr{T}, i::LazyMul{N,Vec{W,I}}) where {W, N, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, true, false, N)
end
@generated function vload(ptr::Ptr{T}, i::LazyMul{N,MM{W,I}}) where {W, N, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, false, false, N)
end
@generated function vload(ptr::Ptr{T}, i::LazyMul{N,Vec{W,I}}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, true, true, N)
end
@generated function vload(ptr::Ptr{T}, i::LazyMul{N,MM{W,I}}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vload_quote(T, I, W, false, true, N)
end

function vstore_quote(::Type{T}, ::Type{I}, W::Int = 1, ivec::Bool = false, mask::Bool = false, constmul::Int = 1, noalias::Bool = false) where {T <: NativeTypes, I <: Integer}
    ityp = vtype(ivec ? W : 1, 'i' * string(8sizeof(I)))
    typ = LLVM_TYPE[T]
    vtyp = vtype(W, typ)
    decl = noalias ? SCOPE_METADATA * STORE_TBAA : STORE_TBAA
    alignment = Base.datatype_alignment(T)
    instrs = offset_ptr(T, I, W, ivec, constmul, '2')
    mask && truncate_mask!(instrs, ivec ? '3' : '2', W, min(8, W), 0)
    if ivec
        storeinstr = "void @llvm.masked.scatter." * suffix(W, T) * '.' * suffix(W, Ptr{T})
        decl *= "declare $storeinstr($vtyp, <$W x $typ*>, i32, <$W x i1>)"
        m = mask ? m = "mask.0" : llvmconst(W, "i1 1")
        # passthrough = mask ? "zeroinitializer" : "undef"
        push!(instrs, "%res = call $storeinstr($vtyp %1, <$W x typ*> %ptr, i32 $alignment, <$W x i1> %$m), !alias.scope !3, !tbaa !5")
    else
        if mask
            suff = suffix(W, T)
            storeinstr = "void @llvm.masked.store." * suff * ".p0" * suff
            decl *= "declare $storeinstr($vtyp, $vtyp*, i32, <$W x i1>)"
            push!(instrs, "%res = call $storeinstr($vtyp %1, $vtyp* %ptr, i32 $alignment, <$W x i1> %mask.0), !alias.scope !3, !tbaa !5")
        else
            push!(instrs, "%res = store $vtyp %1, $vtyp* %ptr, align $alignment, !alias.scope !3, !tbaa !5")
        end
    end
    push!(instrs, "ret void")
    ret = :Cvoid; lret = "void"
    args = Expr(:curly, :Tuple, Expr(:curly, :Ptr, T), isone(W) ? T : Expr(:curly, :NTuple, W, Expr(:curly, :VecElement, T)))
    largs = String[JULIAPOINTERTYPE, vtyp]
    arg_syms = Union{Symbol,Expr}[:ptr, Expr(:call, :data, :v)]
    if !iszero(constmul)
        push!(arg_syms, Expr(:call, :data, :i))
        push!(largs, ityp)
        if ivec & (W > 1)
            push!(args.args, Expr(:curly, :NTuple, W, Expr(:curly, :VecElement, I)))
        else
            push!(args.args, I)
        end
    end
    if mask
        push!(arg_syms, Expr(:call, :data, :m))
        push!(largs, 'i'*string(max(8,W)))
        for (B,U) ∈ [(8,:UInt8),(16,:UInt16),(32,:UInt32),(64,:UInt64)]
            if W ≤ B
                push!(args.args, U)
                break
            end
        end
    end
    llvmcall_expr(decl, join(instrs, "\n"), ret, args, lret, largs, arg_syms)
end

@generated function vstore!(ptr::Ptr{T}, v::T) where {T <: NativeTypes}
    vstore_quote(T, Int, 1, false, false, 0)
end
@generated function vstore!(ptr::Ptr{T}, v::T, i::I) where {T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, 1, false, false, 1)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Vec{W,I}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, false, 1)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Union{I,MM{W,I}}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, false, 1)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Vec{W,I}, m::Mask{W}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, true, 1)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Union{I,MM{W,I}}, m::Mask{W}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, true, 1)
end
@generated function vstore!(ptr::Ptr{T}, v::T, i::LazyMul{N,I}) where {N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, 1, false, false, N)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,Vec{W,I}}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, false, N)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,I}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, false, N)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,MM{W,I}}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, false, N)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,Vec{W,I}}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, true, N)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,I}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, true, N)
end
@generated function vstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,MM{W,I}}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, true, N)
end


@generated function vnoaliasstore!(ptr::Ptr{T}, v::T) where {T <: NativeTypes}
    vstore_quote(T, Int, 1, false, false, 0, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::T, i::I) where {T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, 1, false, false, 1, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Vec{W,I}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, false, 1, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Union{I,MM{W,I}}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, false, 1, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Vec{W,I}, m::Mask{W}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, true, 1, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::Union{I,MM{W,I}}, m::Mask{W}) where {W, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, true, 1, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::T, i::LazyMul{N,I}) where {N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, 1, false, false, N, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,Vec{W,I}}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, false, N, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,I}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, false, N, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,MM{W,I}}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, false, N, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,Vec{W,I}}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, true, true, N, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,I}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, true, N, true)
end
@generated function vnoaliasstore!(ptr::Ptr{T}, v::Vec{W,T}, i::LazyMul{N,MM{W,I}}, m::Mask{W}) where {W, N, T <: NativeTypes, I <: Integer}
    vstore_quote(T, I, W, false, true, N, true)
end



for locality ∈ 0:3, readorwrite ∈ 0:1
    instrs = """
        %addr = inttoptr $JULIAPOINTERTYPE %0 to i8*
        call void @llvm.prefetch(i8* %addr, i32 $readorwrite, i32 $locality, i32 1)
        ret void
    """
    @eval @inline function prefetch(ptr::Ptr{Cvoid}, ::Val{$locality}, ::Val{$readorwrite})
        llvmcall(("declare void @llvm.prefetch(i8*, i32, i32, i32)",$instrs), Cvoid, Tuple{Ptr{Cvoid}}, ptr)
    end
end
@inline prefetch(ptr::Ptr{T}, ::Val{L}, ::Val{R}) = where {T,L,R} = prefetch(Base.unsafe_convert(Ptr{Cvoid}, ptr), Val{L}(), Val{R}())

@inline function prefetch(ptr::Union{AbstractStridedPointer,Ptr}, i, ::Val{Locality}, ::Val{ReadOrWrite}) where {Locality, ReadOrWrite}
    prefetch(gep(ptr, i), Val{Locality}(), Val{ReadOrWrite}())
end
@inline prefetch(ptr::Ptr) = prefetch(ptr, Val{3}(), Val{0}())
@inline prefetch(ptr::Ptr, ::Val{L}) where {L} = prefetch(ptr, Val{L}(), Val{0}())
@inline prefetch(ptr::Ptr, i) = prefetch(ptr, i, Val{3}(), Val{0}())
@inline prefetch(ptr::Ptr, i, ::Val{L}) where {L} = prefetch(ptr, i, Val{L}(), Val{0}())


@inline prefetch0(x, i) = prefetch(gep(stridedpointer(x), (extract_data(i),)), Val{3}(), Val{0}())
@inline prefetch0(x, I::Tuple) = prefetch(gep(stridedpointer(x), extract_data.(I)), Val{3}(), Val{0}())
@inline prefetch0(x, i, j) = prefetch(gep(stridedpointer(x), (extract_data(i), extract_data(j))), Val{3}(), Val{0}())
# @inline prefetch0(x, i, j, oi, oj) = prefetch(gep(stridedpointer(x), (extract_data(i) + extract_data(oi) - 1, extract_data(j) + extract_data(oj) - 1)), Val{3}(), Val{0}())
@inline prefetch1(x, i) = prefetch(gep(stridedpointer(x), (extract_data(i),)), Val{2}(), Val{0}())
@inline prefetch1(x, i, j) = prefetch(gep(stridedpointer(x), (extract_data(i), extract_data(j))), Val{2}(), Val{0}())
# @inline prefetch1(x, i, j, oi, oj) = prefetch(gep(stridedpointer(x), (extract_data(i) + extract_data(oi) - 1, extract_data(j) + extract_data(oj) - 1)), Val{2}(), Val{0}())
@inline prefetch2(x, i) = prefetch(gep(stridedpointer(x), (extract_data(i),)), Val{1}(), Val{0}())
@inline prefetch2(x, i, j) = prefetch(gep(stridedpointer(x), (extract_data(i), extract_data(j))), Val{1}(), Val{0}())
# @inline prefetch2(x, i, j, oi, oj) = prefetch(gep(stridedpointer(x), (extract_data(i) + extract_data(oi) - 1, extract_data(j) + extract_data(oj) - 1)), Val{1}(), Val{0}())

@generated function lifetime_start!(ptr::Ptr{T}, ::Val{L}) where {L,T}
    decl = "declare void @llvm.lifetime.start(i64, i8* nocapture)"
    instrs = "%ptr = inttoptr $JULIAPOINTERTYPE %0 to i8*\ncall void @llvm.lifetime.start(i64 $(L*sizeof(T)), i8* %ptr)\nret void"
    llvmcall_expr(decl, instrs, :Cvoid, :(Tuple{Ptr{$T}}), "void", [JULIAPOINTERTYPE], [:ptr])
end
@generated function lifetime_end!(ptr::Ptr{T}, ::Val{L}) where {L,T}
    decl = "declare void @llvm.lifetime.end(i64, i8* nocapture)"
    instrs = "%ptr = inttoptr $JULIAPOINTERTYPE %0 to i8*\ncall void @llvm.lifetime.end(i64 $(L*sizeof(T)), i8* %ptr)\nret void"
    llvmcall_expr(decl, instrs, :Cvoid, :(Tuple{Ptr{$T}}), "void", [JULIAPOINTERTYPE], [:ptr])
end

@inline lifetime_start!(ptr::Ptr{T}) = lifetime_start!(ptr, Val{-1}())
@inline lifetime_end!(ptr::Ptr{T}) = lifetime_end!(ptr, Val{-1}())
# Fallback is to do nothing. Intention is (e.g.) for PaddedMatrices/StackPointers.
@inline lifetime_start!(::Any) = nothing
@inline lifetime_end!(::Any) = nothing

@generated function compressstore!(ptr::Ptr{T}, v::Vec{W,T}, mask::Mask{W,U}) where {W,T <: NativeTypes, U<:Unsigned}
    @assert 8sizeof(U) >= W
    typ = LLVM_TYPE[T]
    vtyp = "<$W x $typ>"
    mtyp_input = llvmtype(U)
    mtyp_trunc = "i$W"
    instrs = String["%ptr = inttoptr $JULIAPOINTERTYPE %1 to $typ*"]
    truncate_mask!(instrs, '2', W, sizeof(U), 0)
    decl = "declare void @llvm.masked.compressstore.$(suffix(W,T))($vtyp, $typ*, <$W x i1>)"
    push!(instrs, "call void @llvm.masked.compressstore.$(suffix(W,T))($vtyp %0, $typ* %ptr, <$W x i1> %mask.0)\nret void")
    llvmcall_expr(decl, join(instrs,"\n"), :Cvoid, :(Tuple{NTuple{$W,VecElement{$T}}, Ptr{$T}, $U}), "void", [vtyp, JULIAPOINTERTYPE, "i$(8sizeof(U))"], [:(data(v)), :ptr, :(data(mask))])
end

@generated function expandload(ptr::Ptr{T}, mask::Mask{W,U}) where {W, T <: NativeTypes, U<:Unsigned}
    @assert 8sizeof(U) >= W
    typ = LLVM_TYPE[T]
    vtyp = "<$W x $typ>"
    vptrtyp = "<$W x $typ*>"
    mtyp_input = llvmtype(U)
    mtyp_trunc = "i$W"
    instrs = String[]
    push!(instrs, "%ptr = inttoptr $JULIAPOINTERTYPE %0 to $typ*")
    if mtyp_input == mtyp_trunc
        push!(instrs, "%mask = bitcast $mtyp_input %1 to <$W x i1>")
    else
        push!(instrs, "%masktrunc = trunc $mtyp_input %1 to $mtyp_trunc")
        push!(instrs, "%mask = bitcast $mtyp_trunc %masktrunc to <$W x i1>")
    end
    decl = "declare $vtyp @llvm.masked.expandload.$(suffix(W,T))($typ*, <$W x i1>, $vtyp)"
    push!(instrs, "%res = call $vtyp @llvm.masked.expandload.$(suffix(W,T))($typ* %ptr, <$W x i1> %mask, $vtyp zeroinitializer)\nret $vtyp %res")
    llvmcall_expr(decl, join(instrs,"\n"), :(NTuple{$W,VecElement{$T}}), :(Tuple{Ptr{$T}, $U}), vtyp, [JULIAPOINTERTYPE, "i$(8sizeof(U))"], [:ptr, :(data(mask))])
end


