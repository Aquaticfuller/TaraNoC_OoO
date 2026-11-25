// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// How the task scheduler and the cluster hardware number the groups of the mesh.
//
// The scheduler numbers the groups row by row (y * side + x), and its domains likewise; domain d holds the
// groups of the 2 x 2 square at (2 * (d % S), 2 * (d / S)). The cluster hardware numbers the groups in
// Z-order: bit 2i of a group id is y[i], bit 2i+1 is x[i] (its gid_of_xy). The four groups of a domain
// are then the ids 4z .. 4z+3, with z the Z-order id of the domain, which is what the address windows of
// the cluster call a level-1 rectangle. The bridges convert at the boundary.

package tsched_sys_pkg;

  import tsched_pkg::*;

  localparam int unsigned GroupSide = 2 * DomPerSide;

  function automatic int unsigned zorder(input int unsigned x, input int unsigned y);
    zorder = 0;
    for (int unsigned i = 0; i < 16; i++) begin
      zorder |= (((y >> i) & 1) << (2 * i)) | (((x >> i) & 1) << (2 * i + 1));
    end
  endfunction

  // Cluster id of the group the scheduler calls r.
  function automatic int unsigned zid_of_group(input int unsigned r);
`ifdef TSCHED_SYS_RASTER_IDS
    // Regression only: no conversion, as before 2026-11-25, to reproduce what that did.
    return r;
`endif
    return zorder(r % GroupSide, r / GroupSide);
  endfunction

  // Cluster id (level-1 rectangle) of the domain the scheduler calls d.
  function automatic int unsigned zid_of_domain(input int unsigned d);
`ifdef TSCHED_SYS_RASTER_IDS
    return d;
`endif
    return zorder(d % DomPerSide, d / DomPerSide);
  endfunction

  // The same for a domain index that is a signal: a table of constants.
  function automatic logic [7:0] zdom(input dom_t d);
    zdom = '0;
    for (int unsigned k = 0; k < NumDomains; k++) begin
      if (d == dom_t'(k)) zdom = 8'(zid_of_domain(k));
    end
  endfunction

endpackage
