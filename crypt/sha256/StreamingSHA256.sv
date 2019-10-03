`timescale 1ns / 1ps
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
	@brief Streaming SHA-256 core.

	SHA-256 has 64 rounds and a 64-byte block size.

	At one round per clock (iterative), we can sustain streaming of one byte per clock during the compression function.
	Initialization and finalization will reduce throughput slightly.

	After asserting "finalize", wait until X before starting a new hash.
 */
module StreamingSHA256(
	input wire			clk,

	input wire			start,
	input wire			update,
	input wire[31:0]	data_in,
	input wire[2:0]		bytes_valid,
	input wire			finalize,

	output logic		hash_valid	= 0,
	output logic[255:0]	hash		= 0
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Input FIFO. Store one hash block of data plus a bit of room for overflow while we're hashing.

	logic[31:0]			message_len	= 0;

	always_ff @(posedge clk) begin
		if(start)
			message_len	<= 0;
		if(update)
			message_len	<= message_len + bytes_valid;
	end

	//Need to store two hash blocks (2x 64 bytes) so we can accumulate one while hashing another
	logic[7:0]	fifo_rsize;
	logic		fifo_rd		= 0;
	wire[31:0]	fifo_dout;
	ByteInputFifo #(
		.DEPTH(128),
		.USE_BLOCK(0),
		.OUT_REG(1)
	) in_fifo (
		.clk(clk),
		.wr(update),
		.din(data_in),
		.bytes_valid(bytes_valid),
		.flush(finalize),

		.rd(fifo_rd),
		.dout(fifo_dout),
		.underflow(),
		.overflow(),
		.empty(),
		.full(),
		.rsize(fifo_rsize),
		.wsize(),
		.reset(1'b0)
	);

	logic				block_start	= 0;

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Helper function for rotations

	function integer ror(input integer x, input integer bits);
		begin
			return (x << (32-bits)) | (x >> bits);
		end
	endfunction

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Table of constants

	logic[31:0] k[63:0];
	initial begin
		k['h00] <= 32'h428a2f98;
		k['h01] <= 32'h71374491;
		k['h02] <= 32'hb5c0fbcf;
		k['h03] <= 32'he9b5dba5;
		k['h04] <= 32'h3956c25b;
		k['h05] <= 32'h59f111f1;
		k['h06] <= 32'h923f82a4;
		k['h07] <= 32'hab1c5ed5;
		k['h08] <= 32'hd807aa98;
		k['h09] <= 32'h12835b01;
		k['h0a] <= 32'h243185be;
		k['h0b] <= 32'h550c7dc3;
		k['h0c] <= 32'h72be5d74;
		k['h0d] <= 32'h80deb1fe;
		k['h0e] <= 32'h9bdc06a7;
		k['h0f] <= 32'hc19bf174;
		k['h10] <= 32'he49b69c1;
		k['h11] <= 32'hefbe4786;
		k['h12] <= 32'h0fc19dc6;
		k['h13] <= 32'h240ca1cc;
		k['h14] <= 32'h2de92c6f;
		k['h15] <= 32'h4a7484aa;
		k['h16] <= 32'h5cb0a9dc;
		k['h17] <= 32'h76f988da;
		k['h18] <= 32'h983e5152;
		k['h19] <= 32'ha831c66d;
		k['h1a] <= 32'hb00327c8;
		k['h1b] <= 32'hbf597fc7;
		k['h1c] <= 32'hc6e00bf3;
		k['h1d] <= 32'hd5a79147;
		k['h1e] <= 32'h06ca6351;
		k['h1f] <= 32'h14292967;
		k['h20] <= 32'h27b70a85;
		k['h21] <= 32'h2e1b2138;
		k['h22] <= 32'h4d2c6dfc;
		k['h23] <= 32'h53380d13;
		k['h24] <= 32'h650a7354;
		k['h25] <= 32'h766a0abb;
		k['h26] <= 32'h81c2c92e;
		k['h27] <= 32'h92722c85;
		k['h28] <= 32'ha2bfe8a1;
		k['h29] <= 32'ha81a664b;
		k['h2a] <= 32'hc24b8b70;
		k['h2b] <= 32'hc76c51a3;
		k['h2c] <= 32'hd192e819;
		k['h2d] <= 32'hd6990624;
		k['h2e] <= 32'hf40e3585;
		k['h2f] <= 32'h106aa070;
		k['h30] <= 32'h19a4c116;
		k['h31] <= 32'h1e376c08;
		k['h32] <= 32'h2748774c;
		k['h33] <= 32'h34b0bcb5;
		k['h34] <= 32'h391c0cb3;
		k['h35] <= 32'h4ed8aa4a;
		k['h36] <= 32'h5b9cca4f;
		k['h37] <= 32'h682e6ff3;
		k['h38] <= 32'h748f82ee;
		k['h39] <= 32'h78a5636f;
		k['h3a] <= 32'h84c87814;
		k['h3b] <= 32'h8cc70208;
		k['h3c] <= 32'h90befffa;
		k['h3d] <= 32'ha4506ceb;
		k['h3e] <= 32'hbef9a3f7;
		k['h3f] <= 32'hc67178f2;
	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Top level hash state machine

	enum logic[2:0]
	{
		STATE_IDLE			= 0,
		STATE_READ_PIPE		= 1,
		STATE_FILL_W		= 2,
		STATE_PAD			= 3,
		STATE_COMPRESS		= 4,
		STATE_BLOCK_DONE	= 5,
		STATE_DONE			= 6
	} state = STATE_IDLE;

	//The current hash state
	logic[31:0]		w[63:0];
	logic[3:0]		wr_count	= 0;

	//Clear out w at reset to make LA traces look nicer
	initial begin
		for(integer i=0; i<64; i++)
			w[i] = 0;
	end

	logic	finalizing	= 0;
	logic	fifo_rd_ff	= 0;

	logic[31:0]	hash_a	= 0;
	logic[31:0]	hash_b	= 0;
	logic[31:0]	hash_c	= 0;
	logic[31:0]	hash_d	= 0;
	logic[31:0]	hash_e	= 0;
	logic[31:0]	hash_f	= 0;
	logic[31:0]	hash_g	= 0;
	logic[31:0]	hash_h	= 0;

	logic[31:0]	prev_a	= 0;
	logic[31:0]	prev_b	= 0;
	logic[31:0]	prev_c	= 0;
	logic[31:0]	prev_d	= 0;
	logic[31:0]	prev_e	= 0;
	logic[31:0]	prev_f	= 0;
	logic[31:0]	prev_g	= 0;
	logic[31:0]	prev_h	= 0;

	wire[3:0]	pad_word_pos = message_len[5:2];
	wire[1:0]	pad_byte_pos = message_len[1:0];	//number from message bytes from left to right

	logic[6:0]	round	= 0;
	wire[6:0]	rp16	= round + 16;
	wire[6:0]	rp1		= round + 1;
	wire[6:0]	rp14	= round + 14;
	wire[31:0]	w15		= w[rp1];
	wire[31:0]	w2		= w[rp14];

	logic[31:0]	s0;
	logic[31:0]	s1;
	logic[31:0]	ch;
	logic[31:0]	temp1;
	logic[31:0]	temp2;
	logic[31:0]	maj;

	logic		last_block	= 0;

	always_ff @(posedge clk) begin

		fifo_rd		<= 0;
		hash_valid	<= 0;
		fifo_rd_ff	<= fifo_rd;

		case(state)

			STATE_IDLE: begin

				if(start) begin
					hash_a		<= 32'h6a09e667;
					hash_b		<= 32'hbb67ae85;
					hash_c		<= 32'h3c6ef372;
					hash_d		<= 32'ha54ff53a;
					hash_e		<= 32'h510e527f;
					hash_f		<= 32'h9b05688c;
					hash_g		<= 32'h1f83d9ab;
					hash_h		<= 32'h5be0cd19;
					last_block	<= 0;
				end

				//If asked to finalize the current hash, start a new block immediately
				if(finalize) begin

					finalizing	<= 1;
					wr_count	<= 0;

					if(fifo_rsize != 0) begin
						fifo_rd	<= 1;
						state	<= STATE_READ_PIPE;
					end
					else
						state	<= STATE_FILL_W;

				end

			end	//end STATE_IDLE

			//Wait for readout
			STATE_READ_PIPE: begin

				//If there's data on top of what we just read, read more
				if(fifo_rsize > 1)
					fifo_rd		<= 1;

				state	<= STATE_FILL_W;

				//Save old hash state
				prev_a	<= hash_a;
				prev_b	<= hash_b;
				prev_c	<= hash_c;
				prev_d	<= hash_d;
				prev_e	<= hash_e;
				prev_f	<= hash_f;
				prev_g	<= hash_g;
				prev_h	<= hash_h;

			end	//end STATE_READ_PIPE

			STATE_FILL_W: begin

				//Save data as it arrives
				if(fifo_rd_ff) begin
					wr_count	<= wr_count + 1;
					w[wr_count]	<= fifo_dout;

					//If we have all 16 words for this block, don't read more
					if(wr_count == 15)
						state	<= STATE_COMPRESS;

					//If there's data on top of what we just read, read more
					else if(fifo_rsize > 1)
						fifo_rd	<= 1;

				end

				//No data left, prepare to compress.
				//Fill the rest of the block with zeroes.
				if(!fifo_rd_ff || (fifo_rsize <= 1) ) begin
					state	<= STATE_PAD;
					for(integer i=0; i<16; i++) begin
						if(i > wr_count)
							w[i] <= 32'h0;
					end
				end

			end	//end STATE_FILL_W

			//Add padding to the end of the message.
			//0x80, 000...., then length (64 bit big endian BITS) at end of block
			STATE_PAD: begin

				//TODO Edge case: If the message length mod 64 is >55, we can't fit the whole padding.
				//Add the 0x80 wherever it needs to go, but save the length padding for the next block
				if(message_len[5:0] > 55) begin
					last_block								<= 0;
				end

				//All of the padding fits.
				//Add the 0x80 and length
				else begin
					case(pad_byte_pos)
						0: w[pad_word_pos][31:0]	<= 32'h80000000;
						1: w[pad_word_pos][23:0]	<= 24'h800000;
						2: w[pad_word_pos][15:0]	<= 16'h8000;
						3: w[pad_word_pos][7:0]		<= 8'h80;
					endcase
					w[14]									<= { 29'h0, message_len[31:29] };
					w[15]									<= { message_len[28:0], 3'h0 };
					last_block								<= 1;
				end

				round	<= 0;
				state	<= STATE_COMPRESS;

			end	//end STATE_PAD

			STATE_COMPRESS: begin

				//If we're in the first 48 rounds, compute one round of extended w per iteration
				round		<= round + 1;
				if(round < 48) begin
					s0 = ror(w15, 7) ^ ror(w15, 18) ^ w15[31:3];
					s1 = ror(w2, 17) ^ ror(w2, 19) ^ w2[31:10];
					w[rp16]	<= w[rp16 - 16] + s0 + w[rp16 - 7] + s1;
				end

				//Actual compression function
				s1			= ror(hash_e, 6) ^ ror(hash_e, 11) ^ ror(hash_e, 25);
				ch 			= (hash_e & hash_f) ^ (~hash_e & hash_g);
				temp1		= hash_h + s1 + ch + k[round] + w[round];
				s0			= ror(hash_a, 2) ^ ror(hash_a, 13) ^ ror(hash_a, 22);
				maj			= (hash_a & hash_b) ^ (hash_a & hash_c) ^ (hash_b & hash_c);
				temp2		= s0 + maj;

				hash_h		<= hash_g;
				hash_g		<= hash_f;
				hash_f		<= hash_e;
				hash_e		<= hash_d + temp1;
				hash_d		<= hash_c;
				hash_c		<= hash_b;
				hash_b		<= hash_a;
				hash_a		<= temp1 + temp2;

				if(round == 63)
					state	<= STATE_BLOCK_DONE;
			end	//end STATE_EXTEND

			STATE_BLOCK_DONE: begin
				hash_a		<= hash_a + prev_a;
				hash_b		<= hash_b + prev_b;
				hash_c		<= hash_c + prev_c;
				hash_d		<= hash_d + prev_d;
				hash_e		<= hash_e + prev_e;
				hash_f		<= hash_f + prev_f;
				hash_g		<= hash_g + prev_g;
				hash_h		<= hash_h + prev_h;

				//See if we're done with the hash
				if(last_block)
					state	<= STATE_DONE;

				//Are we finalizing, but not at the last block? The length padding didn't fit.
				else if(finalizing) begin
				end

				//Nope, wait for more data
				else
					state	<= STATE_IDLE;

			end	//end STATE_BLOCK_DONE

			STATE_DONE: begin
				hash_valid	<= 1;
				hash		<= { hash_a, hash_b, hash_c, hash_d, hash_e, hash_f, hash_g, hash_h };
				state		<= STATE_IDLE;
				finalizing	<= 0;
				last_block	<= 0;
			end	//end STATE_DONE

		endcase

	end

endmodule