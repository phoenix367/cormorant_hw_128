// tb_functions.svh — shared reference arithmetic for cormorant_tb.
//
// ap_fixed<16,8> encoding:  real_value = raw_int16 / 256.0
//
// VectorOP reference (element-wise, integer arithmetic):
//   ADD/SUB  clip(a ± b,           −32768, +32767)
//   MUL      clip((a × b) >>> 8,   −32768, +32767)
//   DIV      clip(truncate_to_zero(a<<8 / b), −32768, +32767)   (AP_TRN_ZERO)
//   RELU     max(a, 0)
//   RELU6    clip(max(a, 0), 0, 0x0600)
//   act      RELU / RELU6 applied to the op's result (register act)
//
// ConvKernel reference (constant-fill, no padding):
//   acc = n_active × x_raw × w_raw  [+ b_raw×256 if bias]
//   y_raw = clip(acc >>> 8, −32768, +32767)
//
// MatmulKernel reference (constant-fill):
//   c_raw = clip(K × a_raw × b_raw >>> 8, −32768, +32767)
//
// PoolingKernel reference (constant-fill, no padding):
//   MaxPool / AvgPool:  y_float = x_float
//   LpPool p=1, N:      y_float = N × |x_float|
//   LpPool p=2, N:      y_float = poly_sqrt(N × x_float²)  (the kernel's
//                       fixed-point cubic sqrt, bit-exact: ref_poly_sqrt)
//   y_raw = clip(floor(y_float × 256), −32768, +32767)

// -----------------------------------------------------------------------
// Utility
// -----------------------------------------------------------------------
function automatic int unsigned align_up(int unsigned n, int unsigned align_);
    return (n + align_ - 1) & ~(align_ - 1);
endfunction

// -----------------------------------------------------------------------
// VectorOP element-wise reference functions
// -----------------------------------------------------------------------
function automatic logic [15:0] ref_add(logic [15:0] a, b);
    longint signed s = longint'(signed'(a)) + longint'(signed'(b));
    if (s >  32767) s =  32767;
    if (s < -32768) s = -32768;
    return s[15:0];
endfunction

function automatic logic [15:0] ref_sub(logic [15:0] a, b);
    longint signed s = longint'(signed'(a)) - longint'(signed'(b));
    if (s >  32767) s =  32767;
    if (s < -32768) s = -32768;
    return s[15:0];
endfunction

function automatic logic [15:0] ref_mul(logic [15:0] a, b);
    longint signed p = longint'(signed'(a)) * longint'(signed'(b));
    p = p >>> 8;
    if (p >  32767) p =  32767;
    if (p < -32768) p = -32768;
    return p[15:0];
endfunction

function automatic logic [15:0] ref_div(logic [15:0] a, b);
    longint signed q = (longint'(signed'(a)) <<< 8) / longint'(signed'(b));
    if (q >  32767) q =  32767;
    if (q < -32768) q = -32768;
    return q[15:0];
endfunction

function automatic logic [15:0] ref_relu(logic [15:0] a);
    return ($signed(a) < 0) ? 16'h0000 : a;
endfunction

function automatic logic [15:0] ref_relu6(logic [15:0] a);
    if ($signed(a) < 0)         return 16'h0000;
    if ($signed(a) > 16'sh0600) return 16'h0600;
    return a;
endfunction

// Dispatch expected value for one (a, b) pair given op code and the
// fused activation (act) applied to the op's result.
function automatic logic [15:0] compute_ref(
    logic [31:0] op,
    logic [15:0] a,
    logic [15:0] b,
    logic [31:0] act = ACT_NONE
);
    logic [15:0] r;
    case (op)
        OP_ADD:   r = ref_add(a, b);
        OP_SUB:   r = ref_sub(a, b);
        OP_MUL:   r = ref_mul(a, b);
        OP_DIV:   r = ref_div(a, b);
        OP_RELU:  r = ref_relu(a);
        OP_RELU6: r = ref_relu6(a);
        default:  r = 16'hXXXX;             // the activation ops: vop_item.set_exp_row
    endcase
    case (act)
        ACT_RELU:  return ref_relu(r);
        ACT_RELU6: return ref_relu6(r);
        default:   return r;
    endcase
endfunction

// -----------------------------------------------------------------------
// ConvKernel reference (constant-fill input and weights, no padding)
// -----------------------------------------------------------------------
function automatic logic [15:0] compute_conv_const(
    logic [15:0] x_raw,
    logic [15:0] w_raw,
    int unsigned n_active,
    logic [15:0] b_raw,
    logic        use_bias);
    longint signed acc;
    acc = longint'(signed'(x_raw)) * longint'(signed'(w_raw));
    acc = acc * longint'(int'(n_active));
    if (use_bias)
        acc = acc + longint'(signed'(b_raw)) * 256;
    acc = acc >>> 8;
    if (acc >  longint'(32767))  acc =  longint'(32767);
    if (acc < -longint'(32768))  acc = -longint'(32768);
    return acc[15:0];
endfunction

// -----------------------------------------------------------------------
// MatmulKernel reference (constant-fill A and B)
// -----------------------------------------------------------------------
function automatic logic [15:0] compute_mm_const(
    logic [15:0] a_raw, logic [15:0] b_raw, int unsigned k);
    longint signed acc;
    acc = longint'(signed'(a_raw)) * longint'(signed'(b_raw));
    acc = acc * longint'(int'(k));
    acc = acc >>> 8;
    if (acc >  longint'(32767))  acc =  longint'(32767);
    if (acc < -longint'(32768))  acc = -longint'(32768);
    return acc[15:0];
endfunction

// -----------------------------------------------------------------------
// DDR constant fill — write nbytes of a repeated 16-bit val starting at base.
// Requires CHUNK_BYTES, CHUNK_BITS localparams and the `PS macro.
// -----------------------------------------------------------------------
task automatic fill_const_ddr(input [39:0]      base,
                               input int unsigned nbytes,
                               input logic [15:0] val);
    logic [CHUNK_BITS-1:0] buf_mem;
    int unsigned i, n_chunks, rem;
    for (i = 0; i < CHUNK_BYTES / 2; i++)
        buf_mem[i*16 +: 16] = val;
    n_chunks = nbytes / CHUNK_BYTES;
    rem      = nbytes % CHUNK_BYTES;
    for (i = 0; i < n_chunks; i++)
        `PS.write_mem(buf_mem, base + 40'(i * CHUNK_BYTES), CHUNK_BYTES);
    if (rem > 0)
        `PS.write_mem(buf_mem, base + 40'(n_chunks * CHUNK_BYTES), rem);
endtask

// -----------------------------------------------------------------------
// DDR element image — write elems[0..n) (16-bit each) starting at base,
// padded with zeros to a whole 16-byte word (the 128-bit ports read whole
// words; bytes the testbench never wrote are X and trip the AXI checker).
// -----------------------------------------------------------------------
task automatic write_elems_ddr(input [39:0] base, ref logic [15:0] elems[]);
    logic [CHUNK_BITS-1:0] buf_mem;
    int unsigned per_chunk, n, total, i, j, nb;
    per_chunk = CHUNK_BYTES / 2;
    n         = elems.size();
    total     = align_up(n, 8);                 // whole 128-bit words
    for (i = 0; i < total; i += per_chunk) begin
        buf_mem = '0;
        for (j = 0; j < per_chunk && i + j < total; j++)
            buf_mem[j*16 +: 16] = (i + j < n) ? elems[i + j] : 16'h0000;
        nb = ((total - i) < per_chunk ? (total - i) : per_chunk) * 2;
        `PS.write_mem(buf_mem, base + 40'(i * 2), nb);
    end
endtask

// -----------------------------------------------------------------------
// ConvKernel packed weight / bias layout (ConvKernel.h, CONV_OPTIMISATION
// §2.32 / §2.34): standard weight[out_ch][ic_tiles][kh][kw][lanes(ict)],
// lanes 16 except a last half tile of 8 when it holds <= 8 channels, lanes
// past in_ch zero; depthwise weight[out_ch][roundup(kh*kw, 8)]; bias
// roundup(out_ch, 8).
// -----------------------------------------------------------------------
localparam int unsigned CONV_TILE_IC    = 16;
localparam int unsigned CONV_PORT_ELEMS = 8;

function automatic int unsigned conv_ic_tiles(int unsigned in_ch);
    return (in_ch + CONV_TILE_IC - 1) / CONV_TILE_IC;
endfunction

function automatic int unsigned conv_last_tile_lanes(int unsigned in_ch);
    int unsigned rem = in_ch - (conv_ic_tiles(in_ch) - 1) * CONV_TILE_IC;
    return (rem <= CONV_PORT_ELEMS) ? CONV_PORT_ELEMS : CONV_TILE_IC;
endfunction

function automatic int unsigned conv_tile_lanes(int unsigned in_ch, int unsigned ict);
    return (ict + 1 == conv_ic_tiles(in_ch)) ? conv_last_tile_lanes(in_ch) : CONV_TILE_IC;
endfunction

function automatic int unsigned conv_weight_per_m(int unsigned in_ch, int unsigned kh,
                                                  int unsigned kw);
    return kh * kw * ((conv_ic_tiles(in_ch) - 1) * CONV_TILE_IC + conv_last_tile_lanes(in_ch));
endfunction

function automatic int unsigned conv_dw_stride(int unsigned kh, int unsigned kw);
    return align_up(kh * kw, CONV_PORT_ELEMS);
endfunction

function automatic int unsigned conv_weight_numel(int unsigned out_ch, int unsigned in_ch,
        int unsigned kh, int unsigned kw, int unsigned is_depthwise);
    return is_depthwise ? out_ch * conv_dw_stride(kh, kw)
                        : out_ch * conv_weight_per_m(in_ch, kh, kw);
endfunction

// The packed image of a constant weight w (every valid tap / channel = w).
function automatic void conv_const_weights(output logic [15:0] img[],
        input int unsigned out_ch, in_ch, kh, kw, is_depthwise, input logic [15:0] w);
    int unsigned idx, lanes;
    img = new[conv_weight_numel(out_ch, in_ch, kh, kw, is_depthwise)];
    foreach (img[i]) img[i] = 16'h0000;
    for (int unsigned m = 0; m < out_ch; m++) begin
        if (is_depthwise) begin
            for (int unsigned pos = 0; pos < kh * kw; pos++)
                img[m * conv_dw_stride(kh, kw) + pos] = w;
        end else begin
            for (int unsigned ict = 0; ict < conv_ic_tiles(in_ch); ict++) begin
                lanes = conv_tile_lanes(in_ch, ict);
                for (int unsigned pos = 0; pos < kh * kw; pos++)
                    for (int unsigned l = 0; l < lanes; l++)
                        if (ict * CONV_TILE_IC + l < in_ch) begin
                            idx = m * conv_weight_per_m(in_ch, kh, kw)
                                + ict * kh * kw * CONV_TILE_IC + pos * lanes + l;
                            img[idx] = w;
                        end
            end
        end
    end
endfunction

// -----------------------------------------------------------------------
// PoolingKernel reference (constant-fill input, no padding)
// -----------------------------------------------------------------------

// AP_TRN narrowing to frac_bits fractional bits (floor toward -inf).
function automatic real trn(real v, int frac_bits);
    real scale = 2.0 ** frac_bits;
    return $floor(v * scale) / scale;
endfunction

// Bit-exact mirror of PoolingKernel.cpp poly_sqrt() (LpPool p=2 finalize),
// ported from inference-scheduler/src/codegen/_simulate.py _pool_poly_sqrt:
// x = m * 4^k (m in [1, 4), ap_ufixed<18,2>), sqrt(m) by a cubic in
// ap_fixed<16,1> coefficients with ap_fixed<24,4> Horner steps, then
// * 2^k and AccData_t (16 fractional bits).
function automatic real ref_poly_sqrt(real acc);
    real m, c0, c1, c2, c3, t1, t2, sm;
    int  k;
    if (acc <= 0.0) return 0.0;
    m = acc;
    k = 0;
    while (m >= 4.0) begin m = m / 4.0; k++; end
    while (m <  1.0) begin m = m * 4.0; k--; end
    m  = trn(m, 16);
    c0 = trn( 0.4434, 15);
    c1 = trn( 0.6432, 15);
    c2 = trn(-0.0943, 15);
    c3 = trn( 0.0077, 15);
    t1 = trn(c3 * m + c2, 20);
    t2 = trn(t1 * m + c1, 20);
    sm = trn(t2 * m + c0, 20);
    return trn(sm * (2.0 ** k), 16);
endfunction

function automatic logic [15:0] compute_pool_const(
    logic [15:0] x_raw,
    int unsigned n,
    int unsigned pool_type,
    int unsigned lp_order);
    real x_float, y_float;
    longint signed y_int;
    x_float = $itor($signed(x_raw)) / 256.0;
    if (pool_type == 0) begin          // MaxPool: max of N identical = x
        y_float = x_float;
    end else if (pool_type == 1) begin // AvgPool: sum/N = x
        y_float = x_float;
    end else begin                     // LpPool
        if (lp_order == 1)
            y_float = n * (x_float >= 0.0 ? x_float : -x_float);
        else
            y_float = ref_poly_sqrt(trn(n * x_float * x_float, 16));
    end
    y_int = longint'($floor(y_float * 256.0));
    if (y_int >  32767) y_int =  32767;
    if (y_int < -32768) y_int = -32768;
    return y_int[15:0];
endfunction
