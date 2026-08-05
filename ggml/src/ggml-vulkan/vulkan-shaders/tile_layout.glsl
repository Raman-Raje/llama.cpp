#ifndef TILE_LAYOUT_GLSL
#define TILE_LAYOUT_GLSL

// TileK-first activation layout.
//
// A row-major nrows x K tensor is stored so that element (row, kidx) lives at
//   TILEK * ((kidx / TILEK) * nrows + row) + kidx % TILEK
// i.e. the tensor becomes a sequence of K/TILEK tiles, each holding TILEK
// contiguous K values for every one of the nrows rows.
//
// A cooperative-matrix B fragment is TILEK deep and one column wide per lane,
// so in this layout a whole fragment is a single contiguous TILEK-element run
// and the subgroup loads a tile with fully coalesced accesses. Producers
// (rms_norm and friends) write it, mul_mm_tilek.comp consumes it.
//
// Preconditions, enforced host-side by ggml_vk_tilek_can_produce():
//   - K % TILEK == 0
//   - contiguous f32 tensor with a single batch (ne2 == ne3 == 1)
//   - every consumer of the tensor reads it in this layout
//
// TILEK must equal the device's cooperative-matrix K dimension; the host
// checks device->coopmat_k == GGML_VK_TILEK before enabling the layout.

const uint TILEK = 16;
const uint TILEK_LOG2 = 4;

// Index of element (row, kidx) of an nrows x K tensor in TileK-first order.
uint tilek_first_idx(const uint row, const uint kidx, const uint nrows) {
    return TILEK * ((kidx >> TILEK_LOG2) * nrows + row) + (kidx & (TILEK - 1));
}

#endif // TILE_LAYOUT_GLSL
