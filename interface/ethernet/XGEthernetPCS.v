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
	@brief 10 Gigabit Ethernet Base-R PCS. Requires an external GT* for the PMA.
 */
module XGEthernetPCS(

	//Clocks for transmit/receive domains, generated by the transceiver
	//Both are nominally 312.5 MHz, but may have a slight phase difference
	input wire			rx_clk,
	input wire			tx_clk,

	//Incoming data from the GT's 64/66b async gearbox
	input wire			rx_header_valid,
	input wire[1:0]		rx_header,
	input wire[31:0]	rx_data,
	output reg			rx_bitslip	= 0,

	//Outbound data to the GT's 64/66b async gearbox
	output reg			tx_header_valid,
	output reg[1:0]		tx_header	= 0,
	output reg[31:0]	tx_data		= 0,

	//RX XGMII interface (single rate @ 312.5 MHz, rather than double rate @ 162.5 MHz)
	//Bit numbering is changed from the 802.3 spec: we have [31] be lane 0
	//so a 32-bit value will be transmitted in network byte order
	output wire			xgmii_rx_clk,		//echoed rx_clk
	output reg[3:0]		xgmii_rxc	= 0,
	output reg[31:0]	xgmii_rxd	= 0,

	//TX XGMII interface
	//Note that we source the TX clock rather than having it come from the MAC
	output wire			xgmii_tx_clk,
	input wire[3:0]		xgmii_txc,
	input wire[31:0]	xgmii_txd,

	//Link state etc signals
	output reg			block_sync_good,	//indicates valid 64/66b synchronization
	output reg			link_up,
	output reg			remote_fault
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Clock loopback

	//TODO: omit these ports since they serve no real purpose other than convenient naming?
	assign xgmii_rx_clk	= rx_clk;
	assign xgmii_tx_clk	= tx_clk;

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Link state calculation

	//TODO: detect invalid code groups etc and drop the link after too many
	always @(*) begin
		link_up		<= block_sync_good && !remote_fault;
	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Ethernet protocol constants

	//Pull in XGMII table (shared with MAC core)
	`include "XGMII_CtlChars.vh"

	//64/66b sync fields
	localparam SYNC_DATA	= 2'h1;
	localparam SYNC_CONTROL	= 2'h2;

	//64/66b control field types
	localparam CTL_C8		= 8'h1e;	//Eight 7-bit control fields
	localparam CTL_C4_O1_D3	= 8'h2d;	//Four 7-bit control fields, one 4-bit ordered set, three data octets
	localparam CTL_C4_D3	= 8'h33;	//Four 7-bit control field, four padding bits, three data octets
	localparam CTL_D3_O1_D3	= 8'h66;	//Three data octets, one 4-bit ordered set, four padding bits, three data octets
	localparam CTL_D3_O2_D3	= 8'h55;	//Three data octets, two 4-bit ordered set, three data octets
	localparam CTL_D7_START	= 8'h78;	//Seven data octets, start of frame
	localparam CTL_D3_O1_C4	= 8'h4b;	//Three data octets, one 4-bit ordered set, four 7-bit control fields

	//More control field types. These are only legal at the end of a frame
	localparam CTL_C7		= 8'h87;	//Seven padding bits, seven 7-bit control fields
	localparam CTL_D1_C6	= 8'h99;	//One data octet, six padding bits, six 7-bit control fields
	localparam CTL_D2_C5	= 8'haa;	//Two data octets, five padding bits, five 7-bit control fields
	localparam CTL_D3_C4	= 8'hb4;	//Three data octets, four padding bits, four 7-bit control fields
	localparam CTL_D4_C3	= 8'hcc;	//Four data octets, three padding bits, three 7-bit control fields
	localparam CTL_D5_C2	= 8'hd2;	//Five data octets, two padding bits, two 7-bit control fields
	localparam CTL_D6_C1	= 8'he1;	//Six data octets, one padding bit, one 7-bit control field
	localparam CTL_D7_END	= 8'hff;	//Seven data octets at end of frame

	localparam CTL_IDLE		= 7'h00;
	localparam CTL_ERROR	= 7'h1e;

	localparam IDLE_X7		= { CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE };
	localparam IDLE_X6		= { CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE };
	localparam IDLE_X5		= { CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE };
	localparam IDLE_X4		= { CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE };
	localparam IDLE_X3		= { CTL_IDLE, CTL_IDLE, CTL_IDLE };
	localparam IDLE_X2		= { CTL_IDLE, CTL_IDLE};

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX 64/66b block alignment

	reg[3:0]	block_align_errors	= 0;
	reg[10:0]	bitslip_window		= 0;
	reg[7:0]	bitslip_cooldown	= 0;

	always @(posedge rx_clk) begin

		rx_bitslip					<= 0;

		if(rx_header_valid) begin

			//Wait 256 clocks between bitslips to make sure we don't miss the sync
			if(bitslip_cooldown)
				bitslip_cooldown		<= bitslip_cooldown + 1'h1;

			else begin

				bitslip_window			<= bitslip_window + 1'h1;

				//Count bad headers
				if( (rx_header != SYNC_DATA) && (rx_header != SYNC_CONTROL) )
					block_align_errors	<= block_align_errors + 1'h1;

				//More than 15 block align errors in 2048 blocks (arbitrary cutoff for now) triggers re-alignment
				if(block_align_errors == 15) begin
					bitslip_window		<= 0;
					block_align_errors	<= 0;
					rx_bitslip			<= 1;
					bitslip_cooldown	<= 1;
					block_sync_good		<= 0;
				end

				if(bitslip_window == 0)
					block_align_errors	<= 0;

				//Declare block sync good after 128 blocks in a row with valid headers
				if( (bitslip_window == 128) && (block_align_errors == 0) )
					block_sync_good		<= 1;

			end

		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX 64/66b descrambling and bit reordering

	reg[31:0]	rx_data_descrambled	= 0;
	reg[57:0]	rx_scramble = 0;

	integer i;
	always @(posedge rx_clk) begin

		for(i=0; i<32; i=i+1) begin
			rx_data_descrambled[i]		= rx_data[31-i] ^ rx_scramble[38] ^ rx_scramble[57];
			rx_scramble					= { rx_scramble[56:0], rx_data[31-i] };
		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX 64-bit block reassembly and byte reordering

	//todo: can we make this combinatorial?

	reg			rx_block_valid		= 0;
	reg			rx_block_is_control	= 0;
	reg[63:0]	rx_block_data		= 0;

	always @(posedge rx_clk) begin

		if(!rx_header_valid) begin
			rx_block_is_control		<= (rx_header == 2'h2);
			rx_block_valid			<= 0;

			rx_block_data[63:56]	<= rx_data_descrambled[7:0];
			rx_block_data[55:48]	<= rx_data_descrambled[15:8];
			rx_block_data[47:40]	<= rx_data_descrambled[23:16];
			rx_block_data[39:32]	<= rx_data_descrambled[31:24];
		end

		else begin

			rx_block_data[31:24]	<= rx_data_descrambled[7:0];
			rx_block_data[23:16]	<= rx_data_descrambled[15:8];
			rx_block_data[15:8]		<= rx_data_descrambled[23:16];
			rx_block_data[7:0]		<= rx_data_descrambled[31:24];

			rx_block_valid			<= 1;
		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX 64-bit block decoding and XGMII data generation

	reg			last_frame_was_fault	= 0;
	reg[6:0]	remote_fault_count		= 0;
	reg[6:0]	link_ok_count			= 0;

	reg[3:0]	xgmii_rxc_next			= 0;
	reg[31:0]	xgmii_rxd_next			= 0;

	always @(posedge rx_clk) begin

		//Process new blocks
		if(rx_block_valid) begin

			//Default to not being a fault
			last_frame_was_fault			<= 0;

			//Process control frames
			if(rx_block_is_control) begin

				//See what the control type is
				case(rx_block_data[63:56])

					//Eight control characters (normally idles).
					CTL_C8: begin

						//Send all control chars
						xgmii_rxc			<= 4'b1111;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[55:0] == IDLE_X7) begin
							xgmii_rxd		<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
							xgmii_rxd_next	<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
							xgmii_rxd_next	<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_C8

					//Four 7-bit control fields, then jump to fault ordered set
					CTL_C4_O1_D3: begin

						xgmii_rxc			<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[55:28] == IDLE_X4)
							xgmii_rxd		<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else
							xgmii_rxd		<= { XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };

						//For now, assume the ordered set is remote fault
						if(rx_data_descrambled[31:8] == 24'h020000)
							last_frame_was_fault	<= 1;

					end	//end CTL_C4_O1_D3

					//Ordered set, then jump to start of frame and three data octets
					//We don't have enough time to enter a remote fault state so ignore the ordered set.
					//Just send four idles then start the frame
					CTL_D3_O1_D3: begin

						xgmii_rxc			<= 4'b1111;
						xgmii_rxd			<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };

						//Either way, the next block is SOF plus data
						xgmii_rxc_next		<= 4'b1000;
						xgmii_rxd_next		<= { XGMII_CTL_START, rx_block_data[23:0] };

					end	//end CTL_D3_O1_D3

					//Two ordered sets
					CTL_D3_O2_D3: begin

						//This means a fault of some kind. For now, only implement remote fault
						if(rx_data_descrambled[31:8] == 24'h020000)
							last_frame_was_fault	<= 1;

					end	//end CTL_D3_O2_D3

					//Ordered set, then jump to control codes
					//We don't have enough time to enter a remote fault state so ignore the ordered set.
					//Just send the control codes
					CTL_D3_O1_C4: begin

						xgmii_rxc			<= 4'b1111;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[27:0] == IDLE_X4) begin
							xgmii_rxd		<= { XGMII_CTL_END, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
							xgmii_rxd_next	<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= { XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
							xgmii_rxd_next	<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_D3_O1_C4

					//Start of frame, plus seven data octets
					CTL_D7_START: begin
						xgmii_rxc			<= 4'b1000;
						xgmii_rxd			<= { XGMII_CTL_START, rx_block_data[55:32] };

						xgmii_rxc_next		<= 4'b0000;
						xgmii_rxd			<= rx_block_data[31:0];

					end	//end CTL_D7_START

					//Four control characters, three padding bits, start of frame, three data octets
					CTL_C4_D3: begin

						xgmii_rxc			<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[55:28] == IDLE_X4)
							xgmii_rxd		<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else
							xgmii_rxd		<= { XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };

						//Either way, the next block is SOF plus data
						xgmii_rxc_next		<= 4'b1000;
						xgmii_rxd_next		<= { XGMII_CTL_START, rx_block_data[23:0] };

					end	//end CTL_C4_D3

					//Everything past here indicates end-of-frame

					//End of frame plus seven control characters (should be idles)
					CTL_C7: begin

						//Send all control chars
						xgmii_rxc			<= 4'b1111;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[55:0] == IDLE_X7) begin
							xgmii_rxd		<= { XGMII_CTL_END, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
							xgmii_rxd_next	<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= { XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
							xgmii_rxd_next	<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_C7

					//Data byte, end of frame, six control characters (should be idles)
					CTL_D1_C6: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0111;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[41:0] == IDLE_X6) begin
							xgmii_rxd		<= { rx_block_data[55:48], XGMII_CTL_END, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
							xgmii_rxd_next	<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= { rx_block_data[55:48], XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
							xgmii_rxd_next	<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_D1_C6

					//Two data bytes, end of frame, five control characters (should be idles)
					CTL_D2_C5: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0011;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[34:0] == IDLE_X5) begin
							xgmii_rxd		<= { rx_block_data[55:40], XGMII_CTL_END, XGMII_CTL_IDLE };
							xgmii_rxd_next	<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= { rx_block_data[55:40], XGMII_CTL_END, XGMII_CTL_ERROR };
							xgmii_rxd_next	<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_D2_C5

					//Three data bytes, end of frame, four control characters (should be idles)
					CTL_D3_C4: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0001;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[27:0] == IDLE_X4) begin
							xgmii_rxd		<= { rx_block_data[55:32], XGMII_CTL_END };
							xgmii_rxd_next	<= { XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= { rx_block_data[55:32], XGMII_CTL_END };
							xgmii_rxd_next	<= { XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_D3_C4

					//Four data bytes, end of frame, three control characters (should be idles)
					CTL_D4_C3: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0000;
						xgmii_rxc_next		<= 4'b1111;

						//If all idles, we're good
						if(rx_block_data[20:0] == IDLE_X3) begin
							xgmii_rxd		<= rx_block_data[55:24];
							xgmii_rxd_next	<= { XGMII_CTL_END, XGMII_CTL_IDLE, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= rx_block_data[55:24];
							xgmii_rxd_next	<= { XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_D4_C3

					//Five data bytes, end of frame, two control characters (should be idles)
					CTL_D5_C2: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0000;
						xgmii_rxc_next		<= 4'b0111;

						//If all idles, we're good
						if(rx_block_data[13:0] == IDLE_X2) begin
							xgmii_rxd		<= rx_block_data[55:24];
							xgmii_rxd_next	<= { rx_block_data[23:16], XGMII_CTL_END, XGMII_CTL_IDLE, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= rx_block_data[55:24];
							xgmii_rxd_next	<= { rx_block_data[23:16], XGMII_CTL_END, XGMII_CTL_ERROR, XGMII_CTL_ERROR };
						end

					end	//end CTL_D5_C2

					//Six data bytes, end of frame, one control character (should be idle)
					CTL_D6_C1: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0000;
						xgmii_rxc_next		<= 4'b0011;

						//If all idles, we're good
						if(rx_block_data[7:0] == CTL_IDLE) begin
							xgmii_rxd		<= rx_block_data[55:24];
							xgmii_rxd_next	<= { rx_block_data[23:8], XGMII_CTL_END, XGMII_CTL_IDLE };
						end

						//Only other legal control character is error.
						//Don't bother counting them, generate a burst of all error characters
						else begin
							xgmii_rxd		<= rx_block_data[55:24];
							xgmii_rxd_next	<= { rx_block_data[23:8], XGMII_CTL_END, XGMII_CTL_ERROR };
						end

					end	//end CTL_D6_C1

					//Seven data bytes, end of frame
					CTL_D7_END: begin

						//Send all control chars after the end of the packet
						xgmii_rxc			<= 4'b0000;
						xgmii_rxc_next		<= 4'b0001;

						xgmii_rxd			<= rx_block_data[55:24];
						xgmii_rxd_next	<= { rx_block_data[23:0], XGMII_CTL_END };

					end	//end CTL_D7_END

				endcase

			end

			//Process data frames
			else begin
				xgmii_rxc			<= 4'b0000;
				xgmii_rxd			<= rx_block_data[63:32];

				xgmii_rxc_next		<= 4'b0000;
				xgmii_rxd_next		<= rx_block_data[31:0];
			end

			//Link fault state tracking
			//As per 46.3.4.3 we need 128 consecutive fault/not fault states to change the fault flags
			if(last_frame_was_fault) begin
				remote_fault_count	<= remote_fault_count + 1'h1;
				link_ok_count		<= 0;

				if(remote_fault_count == 127)
					remote_fault	<= 1;
			end
			else begin
				link_ok_count		<= link_ok_count + 1'h1;
				remote_fault_count	<= 0;

				if(link_ok_count == 127)
					remote_fault	<= 0;
			end

		end

		//Continue and send the second half of a block
		else begin
			xgmii_rxc	<= xgmii_rxc_next;
			xgmii_rxd	<= xgmii_rxd_next;
		end

		//If remote fault is set, this overrides all other XGMII state
		if(remote_fault) begin
			xgmii_rxc	<= 4'b1000;
			xgmii_rxd	<= XGMII_ORDERED_SET_REMOTE_FAULT;
		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// TX 64-bit block generation

	//Build a 64-bit XGMII data block
	reg				xgmii_x64_valid	= 0;
	reg[7:0]		xgmii_txc_x64	= 0;
	reg[63:0]		xgmii_txd_x64	= 0;

	always @(posedge tx_clk) begin

		//TODO: check if this phasing is right
		if(tx_header_valid) begin
			xgmii_x64_valid			<= 0;
			xgmii_txc_x64[7:4]		<= xgmii_txc;
			xgmii_txd_x64[63:32]	<= xgmii_txd;
		end
		else begin
			xgmii_x64_valid			<= 1;
			xgmii_txc_x64[3:0]		<= xgmii_txc;
			xgmii_txd_x64[31:0]		<= xgmii_txd;
		end

	end

	reg[1:0]		tx_header_next		= SYNC_CONTROL;
	reg[1:0]		tx_header_next_ff	= SYNC_CONTROL;
	reg[63:0]		tx_64b_data			=
	{
		CTL_C8,
		CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE
	};

	wire[7:0]		tx_has_start =
	{
		xgmii_txc_x64[7] && (xgmii_txd_x64[63:56] == XGMII_CTL_START),
		xgmii_txc_x64[6] && (xgmii_txd_x64[55:48] == XGMII_CTL_START),
		xgmii_txc_x64[5] && (xgmii_txd_x64[47:40] == XGMII_CTL_START),
		xgmii_txc_x64[4] && (xgmii_txd_x64[39:32] == XGMII_CTL_START),
		xgmii_txc_x64[3] && (xgmii_txd_x64[31:24] == XGMII_CTL_START),
		xgmii_txc_x64[2] && (xgmii_txd_x64[23:16] == XGMII_CTL_START),
		xgmii_txc_x64[1] && (xgmii_txd_x64[15:8 ] == XGMII_CTL_START),
		xgmii_txc_x64[0] && (xgmii_txd_x64[7:0  ] == XGMII_CTL_START)
	};

	wire[7:0]		tx_has_end =
	{
		xgmii_txc_x64[7] && (xgmii_txd_x64[63:56] == XGMII_CTL_END),
		xgmii_txc_x64[6] && (xgmii_txd_x64[55:48] == XGMII_CTL_END),
		xgmii_txc_x64[5] && (xgmii_txd_x64[47:40] == XGMII_CTL_END),
		xgmii_txc_x64[4] && (xgmii_txd_x64[39:32] == XGMII_CTL_END),
		xgmii_txc_x64[3] && (xgmii_txd_x64[31:24] == XGMII_CTL_END),
		xgmii_txc_x64[2] && (xgmii_txd_x64[23:16] == XGMII_CTL_END),
		xgmii_txc_x64[1] && (xgmii_txd_x64[15:8 ] == XGMII_CTL_END),
		xgmii_txc_x64[0] && (xgmii_txd_x64[7:0  ] == XGMII_CTL_END)
	};

	wire			tx_has_data = (xgmii_txc_x64 == 8'h0);

	always @(posedge tx_clk) begin

		tx_header_next_ff		<= tx_header_next;

		if(xgmii_x64_valid) begin

			//Everything is control characters except packet data
			//so default to that
			tx_header_next		<=	SYNC_CONTROL;

			//Start-of-frame in first block
			//Assume everything after this is data octets (preamble) and send them
			if(tx_has_start[7])
				tx_64b_data		<= { CTL_D7_START, xgmii_txd_x64[55:0] };

			//Start-of-frame in second block
			//Send four idles, four padding bits, then the first three preamble octets
			else if(tx_has_start[3])
				tx_64b_data		<= { CTL_C4_D3, IDLE_X4, 4'b0, xgmii_txd_x64[23:0] };

			//Eight data octets - forward them along
			else if(tx_has_data) begin
				tx_header_next	<= SYNC_DATA;
				tx_64b_data		<= xgmii_txd_x64;
			end

			//End of frame at any position in the block
			//Send remaining data words, end of frame, then idles
			//TODO: check rest of the data in the block to make sure there's no TX errors etc to forward
			else if(tx_has_end[7])
				tx_64b_data		<= { CTL_C7, 7'h0, IDLE_X7 };
			else if(tx_has_end[6])
				tx_64b_data		<= { CTL_D1_C6, xgmii_txd_x64[63:56], 6'h0, IDLE_X6 };
			else if(tx_has_end[5])
				tx_64b_data		<= { CTL_D2_C5, xgmii_txd_x64[63:48], 5'h0, IDLE_X5 };
			else if(tx_has_end[4])
				tx_64b_data		<= { CTL_D3_C4, xgmii_txd_x64[63:40], 4'h0, IDLE_X4 };
			else if(tx_has_end[3])
				tx_64b_data		<= { CTL_D4_C3, xgmii_txd_x64[63:32], 3'h0, IDLE_X3 };
			else if(tx_has_end[2])
				tx_64b_data		<= { CTL_D5_C2, xgmii_txd_x64[63:24], 2'h0, IDLE_X2 };
			else if(tx_has_end[1])
				tx_64b_data		<= { CTL_D6_C1, xgmii_txd_x64[63:16], 1'h0, CTL_IDLE };
			else if(tx_has_end[0])
				tx_64b_data		<= { CTL_D7_END, xgmii_txd_x64[63:8]};

			//Nothing to do, send idles
			else begin
				tx_64b_data			<=
				{
					CTL_C8,
					CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE, CTL_IDLE
				};
			end

		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// TX 32-bit block generation and byte reordering

	//Pull out the right 32-bit word and twiddle bit odering
	//We have two cycle latency through the line coding block right now, so send the leftmost block
	//when tx_header_valid is about to go high
	reg[31:0]		tx_32b_data		= 0;
	always @(posedge tx_clk) begin

		if(!tx_header_valid) begin
			tx_32b_data[7:0]		<= tx_64b_data[63:56];
			tx_32b_data[15:8]		<= tx_64b_data[55:48];
			tx_32b_data[23:16]		<= tx_64b_data[47:40];
			tx_32b_data[31:24]		<= tx_64b_data[39:32];
		end

		else begin
			tx_32b_data[7:0]		<= tx_64b_data[31:24];
			tx_32b_data[15:8]		<= tx_64b_data[23:16];
			tx_32b_data[23:16]		<= tx_64b_data[15:8];
			tx_32b_data[31:24]		<= tx_64b_data[7:0];
		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// TX scrambling and bit reordering

	reg[57:0] 	tx_scramble = 0;

	reg			tx_scramble_temp;

	always @(posedge tx_clk) begin

		tx_header					<= tx_header_next_ff;
		tx_header_valid				<= !tx_header_valid;

		for(i=0; i<32; i=i+1) begin
			tx_scramble_temp			= tx_32b_data[i] ^ tx_scramble[38] ^ tx_scramble[57];

			tx_data[31-i]				= tx_scramble_temp;
			tx_scramble					= { tx_scramble[56:0], tx_scramble_temp };
		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// LA runs in SERDES TX clock domain

	/*
	wire	trig_out;
	reg		trig_out_ack	= 0;

	always @(posedge tx_clk) begin
		trig_out_ack	<= trig_out;
	end

	ila_0 ila(
		.clk(tx_clk),

		.probe0(xgmii_txc),
		.probe1(xgmii_txd),
		.probe2(tx_header_next),
		.probe3(tx_64b_data),
		.probe4(xgmii_x64_valid),
		.probe5(xgmii_txc_x64),
		.probe6(xgmii_txd_x64),
		.probe7(tx_32b_data),

		.probe8(tx_has_start),
		.probe9(tx_has_end),
		.probe10(tx_has_data),

		.trig_out(trig_out),
		.trig_out_ack(trig_out_ack)
	);
	*/

endmodule
