`timescale 1ns / 1ps
`default_nettype none
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2018 Andrew D. Zonenberg                                                                          *
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
	@brief 10/100/1000 Mbps Ethernet MAC

	Interface-compatible with XGEthernetMAC.

	Conventions
		rx_frame_start is asserted before, not simultaneous with, first assertion of rx_frame_data_valid
		rx_frame_bytes_valid is always 4 until last word in the packet, at which point it may take any value
		rx_frame_commit is asserted after, not simultaneous with, last assertion of rx_frame_data_valid
 */
module TriSpeedEthernetMAC(

	//XMGII bus
	input wire			gmii_rx_clk,
	input wire			gmii_rx_dv,
	input wire			gmii_rx_er,
	input wire[7:0]		gmii_rxd,

	input wire			gmii_tx_clk,
	output logic		gmii_tx_en		= 0,
	output logic		gmii_tx_er		= 0,
	output logic[7:0]	gmii_txd		= 0,

	//Link state flags (reset stuff as needed when link is down)
	//Synchronous to RX clock
	input wire			link_up,

	//Data bus to upper layer stack (synchronous to RX clock)
	//Streaming bus, don't act on this data until rx_frame_commit goes high
	output logic		rx_frame_start			= 0,
	output logic		rx_frame_data_valid		= 0,
	output logic[2:0]	rx_frame_bytes_valid	= 0,
	output logic[31:0]	rx_frame_data			= 0,
	output logic		rx_frame_commit			= 0,
	output logic		rx_frame_drop			= 0,

	//Data bus from upper layer stack (synchronous to TX clock).
	//Only 8 bits wide, TX buffer has to rate-match
	//Well-formed layer 2 frames minus padding (if needed) and CRC.
	//No commit/drop flags, everything that comes in here gets sent.
	input wire			tx_frame_start,
	input wire			tx_frame_data_valid,
	input wire[7:0]		tx_frame_data
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX CRC calculation

	//Do it 8 bits wide, every clock, to save area
	wire		rx_crc_reset	= (rx_state == RX_STATE_PREAMBLE);
	wire		rx_crc_update	= gmii_rx_dv && (rx_state == RX_STATE_FRAME_DATA);
	wire[31:0]	rx_crc_calculated;

	CRC32_Ethernet rx_crc_calc(
		.clk(gmii_rx_clk),
		.reset(rx_crc_reset),
		.update(rx_crc_update),
		.din(gmii_rxd),
		.crc_flipped(rx_crc_calculated)
	);

	//Delay by 5 cycles so the CRC is there when we want to use it
	reg[31:0]	rx_crc_calculated_ff	= 0;
	reg[31:0]	rx_crc_calculated_ff2	= 0;
	reg[31:0]	rx_crc_calculated_ff3	= 0;
	reg[31:0]	rx_crc_calculated_ff4	= 0;
	reg[31:0]	rx_crc_calculated_ff5	= 0;

	always_ff @(posedge gmii_rx_clk) begin
		rx_crc_calculated_ff5	<= rx_crc_calculated_ff4;
		rx_crc_calculated_ff4	<= rx_crc_calculated_ff3;
		rx_crc_calculated_ff3	<= rx_crc_calculated_ff2;
		rx_crc_calculated_ff2	<= rx_crc_calculated_ff;
		rx_crc_calculated_ff	<= rx_crc_calculated;
	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX stuff

	logic[1:0]	rx_bytepos				= 0;
	logic[31:0]	rx_pending_data			= 0;

	logic		rx_frame_data_valid_adv	= 0;
	logic[31:0]	rx_frame_data_adv		= 0;

	enum logic[3:0]
	{
		RX_STATE_IDLE		= 4'h0,
		RX_STATE_DROP		= 4'h1,
		RX_STATE_PREAMBLE	= 4'h2,
		RX_STATE_FRAME_DATA	= 4'h3,
		RX_STATE_CRC		= 4'h4
	}
	rx_state = RX_STATE_IDLE;

	wire[31:0]	rx_crc_expected	= rx_pending_data;

	always_ff @(posedge gmii_rx_clk) begin

		rx_frame_start				<= 0;
		rx_frame_data_valid			<= 0;
		rx_frame_bytes_valid		<= 0;
		rx_frame_commit				<= 0;
		rx_frame_drop				<= 0;

		case(rx_state)

			//Wait for a new frame to start
			RX_STATE_IDLE: begin

				//Ignore rx_er outside of a packet

				//Something is here!
				if(gmii_rx_dv) begin

					//Should be a preamble (55 55 55 ...)
					if( (gmii_rxd == 8'h55) && !gmii_rx_er )
						rx_state			<= RX_STATE_PREAMBLE;

					//Anything else is a problem, ignore it
					else
						rx_state			<= RX_STATE_DROP;
				end

			end	//end RX_STATE_IDLE

			//Wait for SFD
			RX_STATE_PREAMBLE: begin

				//Drop frame if it truncates before the SFD
				if(!gmii_rx_dv)
					rx_state				<= RX_STATE_IDLE;

				//Tell the upper layer we are starting the frame when we hit the SFD.
				//No point in even telling them about runt packets that end during the preamble.
				else if(gmii_rxd == 8'hd5) begin
					rx_frame_start			<= 1;
					rx_bytepos				<= 0;
					rx_state				<= RX_STATE_FRAME_DATA;
					rx_frame_data_valid_adv	<= 0;
				end

				//Still preamble, keep going
				else if(gmii_rxd == 8'h55) begin
				end

				//Anything else before the SFD is an error, drop it.
				//Don't have to tell upper layer as we never even told them a frame was coming.
				else
					rx_state				<= RX_STATE_DROP;

			end	//end RX_STATE_PREAMBLE

			//Actual packet data
			RX_STATE_FRAME_DATA: begin

				//End of frame - push any fractional message word that might be waiting
				if(!gmii_rx_dv) begin
					rx_state					<= RX_STATE_CRC;

					if(rx_bytepos != 0) begin
						rx_frame_bytes_valid	<= rx_bytepos;
						rx_frame_data_valid		<= 1;
					end

					case(rx_bytepos)

						1: rx_frame_data		<= { rx_frame_data_adv[31:24], 24'h0 };
						2: rx_frame_data		<= { rx_frame_data_adv[31:16], 16'h0 };
						3: rx_frame_data		<= { rx_frame_data_adv[31:8], 8'h0 };

					endcase

				end

				//Frame data
				else begin
					rx_pending_data				<= { rx_pending_data[23:0], gmii_rxd };
					rx_bytepos					<= rx_bytepos + 1'h1;

					//We've received a full word!
					if(rx_bytepos == 3) begin

						//Save this word in the buffer for next time around
						rx_frame_data_valid_adv	<= 1;
						rx_frame_data_adv		<= { rx_pending_data[23:0], gmii_rxd };

						//Send the PREVIOUS word to the host
						//We need a pipeline delay because of the CRC - don't want to get the CRC confused with application layer data!
						if(rx_frame_data_valid_adv) begin
							rx_frame_data_valid		<= 1;
							rx_frame_data			<= rx_frame_data_adv;
							rx_frame_bytes_valid	<= 4;
						end

					end
				end

			end	//end RX_STATE_FRAME_DATA

			RX_STATE_CRC: begin
				rx_state			<= RX_STATE_IDLE;

				//Validate the CRC (details depend on length of the packet)
				if(rx_crc_calculated_ff5 == rx_crc_expected)
					rx_frame_commit	<= 1;
				else
					rx_frame_drop	<= 1;

			end

			//If skipping a frame due to a fault, ignore everything until the frame ends
			RX_STATE_DROP: begin
				if(!gmii_rx_dv)
					rx_state		<= RX_STATE_IDLE;
			end	//end RX_STATE_DROP

		endcase

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// TX stuff

	enum logic[3:0]
	{
		TX_STATE_IDLE		= 4'h0,
		TX_STATE_PREAMBLE	= 4'h1,
		TX_STATE_FRAME_DATA	= 4'h2,
		TX_STATE_PADDING	= 4'h3,
		TX_STATE_CRC_0		= 4'h4,
		TX_STATE_CRC_1		= 4'h5,
		TX_STATE_IFG		= 4'h6
	}
	tx_state = TX_STATE_IDLE;

	logic[3:0] tx_count	= 0;

	//Tiny FIFO for packet data that showed up during the preamble
	logic		tx_fifo_pop	= 0;
	wire[7:0]	tx_fifo_rdata;
	wire[4:0]	tx_fifo_rsize;

	logic[10:0]	tx_frame_len = 0;

	SingleClockFifo #(
		.WIDTH(8),
		.DEPTH(16),
		.USE_BLOCK(0)
	) tx_fifo (
		.clk(gmii_tx_clk),

		.wr(tx_frame_data_valid),
		.din(tx_frame_data),

		.rd(tx_fifo_pop),
		.dout(tx_fifo_rdata),

		.overflow(),
		.underflow(),
		.empty(),
		.full(),
		.rsize(tx_fifo_rsize),
		.wsize(),
		.reset(tx_frame_start)		//wipe any existing junk when a frame starts
	);

	logic		tx_en			= 0;
	logic[7:0]	tx_data			= 0;
	wire		tx_crc_update	= (tx_state == TX_STATE_FRAME_DATA) || (tx_state == TX_STATE_PADDING);
	wire[31:0]	tx_crc;
	logic[7:0]	tx_crc_din;

	always_comb begin
		if(tx_state == TX_STATE_FRAME_DATA)
			tx_crc_din	<= tx_fifo_rdata;
		else
			tx_crc_din	<= 0;
	end

	CRC32_Ethernet tx_crc_calc(
		.clk(gmii_tx_clk),
		.reset(tx_frame_start),
		.update(tx_crc_update),
		.din(tx_crc_din),
		.crc_flipped(tx_crc)
	);

	always_ff @(posedge gmii_tx_clk) begin

		gmii_tx_en	<= 0;
		gmii_tx_er	<= 0;
		gmii_txd	<= 0;

		tx_en		<= 0;
		tx_data		<= 0;

		tx_fifo_pop	<= 0;

		//Pipeline delay on GMII TX bus, so we have time to compute the CRC
		gmii_tx_en	<= tx_en;
		gmii_txd	<= tx_data;

		if(tx_state != TX_STATE_IDLE)
			tx_frame_len	<= tx_frame_len + 1'h1;

		case(tx_state)

			//If a new frame is starting, begin the preamble while buffering the message content
			TX_STATE_IDLE: begin
				tx_frame_len		<= 0;
				if(tx_frame_start) begin
					tx_en			<= 1;
					tx_data			<= 8'h55;
					tx_count		<= 1;
					tx_state		<= TX_STATE_PREAMBLE;
					tx_frame_len	<= 1;
				end
			end	//end TX_STATE_IDLE

			//Send the preamble
			TX_STATE_PREAMBLE: begin

				tx_en			<= 1;
				tx_data			<= 8'h55;

				tx_count		<= tx_count + 1'h1;

				//Start popping message data
				if(tx_count >= 6)
					tx_fifo_pop	<= 1;

				if(tx_count == 7) begin
					tx_data		<= 8'hd5;
					tx_count	<= 0;
					tx_state	<= TX_STATE_FRAME_DATA;
				end

			end	//end TX_STATE_PREAMBLE

			TX_STATE_FRAME_DATA: begin

				//Not last word? Pop it
				if(tx_fifo_rsize > 1)
					tx_fifo_pop	<= 1;

				//Packet must be at least 66 bytes including preamble
				else begin
					if(tx_frame_len > 66)
						tx_state	<= TX_STATE_CRC_0;
					else
						tx_state	<= TX_STATE_PADDING;
				end

				tx_en	<= 1;
				tx_data	<= tx_fifo_rdata;

			end	//end TX_STATE_FRAME_DATA

			//Wait for CRC calculation
			TX_STATE_CRC_0: begin
				tx_state	<= TX_STATE_CRC_1;
			end	//end TX_STATE_CRC_0

			//Actually send the CRC
			TX_STATE_CRC_1: begin

				//Transmit directly (no forwarding)
				gmii_tx_en	<= 1;

				tx_count	<= tx_count + 1'h1;

				if(tx_count == 3) begin
					tx_count	<= 0;
					tx_state	<= TX_STATE_IFG;
				end

				case(tx_count)
					0:	gmii_txd	<= tx_crc[31:24];
					1:	gmii_txd	<= tx_crc[23:16];
					2:	gmii_txd	<= tx_crc[15:8];
					3:	gmii_txd	<= tx_crc[7:0];

				endcase
			end	//end TX_STATE_CRC_1

			//Pad frame out to 68 bytes including preamble but not FCS
			TX_STATE_PADDING: begin
				tx_en	<= 1;
				tx_data	<= 0;

				if(tx_frame_len > 66)
					tx_state	<= TX_STATE_CRC_0;

			end	//end TX_STATE_PADDING

			//Inter-frame gap (min 12 octets)
			TX_STATE_IFG: begin
				tx_count	<= tx_count + 1'h1;

				if(tx_count == 11)
					tx_state	<= TX_STATE_IDLE;

			end	//end TX_STATE_IFG

		endcase

	end

endmodule
