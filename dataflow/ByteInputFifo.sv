`timescale 1ns / 1ps
`default_nettype none
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2019 Andrew D. Zonenberg                                                                          *
* All rights reserved.                                                                                                 *
*                                                                                                                      *
* Redistribution and use in source and binary forms, with or without modification, are permitted provided that the     *
* following conditions are met:                                                                                        *
*                                                                                                                      *
*    * Redistributions of source code must retain the above copyright notice, this list of conditions, and the         *
*      following disclaimer.                                                                                           *
*                                                                                                                      *
*    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the       *
*      following disclaimer in the documentation and/or other materials provided with the distribution.                *
*                                                                                                                      *
*    * Neither the name of the author nor the names of any contributors may be used to endorse or promote products     *
*      derived from this software without specific prior written permission.                                           *
*                                                                                                                      *
* THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   *
* TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL *
* THE AUTHORS BE HELD LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES        *
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR       *
* BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT *
* (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE       *
* POSSIBILITY OF SUCH DAMAGE.                                                                                          *
*                                                                                                                      *
***********************************************************************************************************************/

/**
	@file
	@author Andrew D. Zonenberg
	@brief Wrapper around SingleClockFifo for allowing arbitrary sized input (1-4 bytes per clock)
 */
module ByteInputFifo #(
	parameter DEPTH 		= 512,
	localparam ADDR_BITS 	= $clog2(DEPTH),
	parameter USE_BLOCK 	= 1,
	parameter OUT_REG 		= 1
)(
	input wire					clk,
	input wire					wr,
	input wire[31:0]			din,
	input wire[2:0]				bytes_valid,	//1-4
	input wire					flush,			//push din_temp into the fifo
												//(must not be same cycle as wr)

	input wire					rd,
	output wire[31:0]			dout,

	output wire					overflow,
	output wire					underflow,

	output wire					empty,
	output wire					full,

	output logic[ADDR_BITS:0]	rsize,
	output wire[ADDR_BITS:0]	wsize,

	input wire					reset
);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Width conversion

	wire		fifo_wr;
	wire[31:0]	fifo_din;

	ByteToWordConverter converter (
		.clk(clk),
		.wr(wr),
		.din(din),
		.bytes_valid(bytes_valid),
		.flush(flush),
		.reset(reset),

		.dout_valid(fifo_wr),
		.dout_bytes_valid(),	//for now don't track this
		.dout(fifo_din)
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// The actual FIFO

	wire[ADDR_BITS:0] rsize_raw;
	always_comb begin
		if(temp_valid > 0)
			rsize = rsize_raw + 1;
		else
			rsize = rsize_raw;
	end


	SingleClockFifo #(
		.WIDTH(32),
		.DEPTH(DEPTH),
		.USE_BLOCK(USE_BLOCK),
		.OUT_REG(OUT_REG)
	) fifo (
		.clk(clk),
		.wr(fifo_wr),
		.din(fifo_din),
		.rd(rd),
		.dout(dout),
		.underflow(underflow),
		.overflow(overflow),
		.empty(empty),
		.full(full),
		.rsize(rsize_raw),
		.wsize(wsize),
		.reset(reset)
	);

endmodule
