`default_nettype none
`timescale 1ns / 1ps
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2017 Andrew D. Zonenberg                                                                          *
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
	@brief Driver for a Solomon SSD1306 OLED controller
 */
module SSD1306 #(
	parameter INTERFACE = "SPI"		//this is the only supported interface for now
) (

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// System-wide stuff

	input wire clk,					//Core and interface clock
	input wire[15:0] clkdiv,		//SPI clock divisor

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// To display

	//System control signals
	output reg rst_out_n = 0,		//Reset output to display
	output reg vbat_en_n = 1,		//Power rail enables
	output reg vdd_en_n = 1,

	//SPI
	output wire spi_sck,			//4-wire SPI bus to display (MISO not used by this core)
	output wire spi_mosi,
	output reg spi_cs_n = 1,

	//Misc data lines
	output reg cmd_n = 0,			//SPI command/data flag

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// To GPU

	//Command inputs
	input wire powerup,				//Request to turn the display on
	input wire powerdown,			//Request to turn the display off
	input wire refresh,				//Request to refresh the display from the GPU framebuffer

	//Status outputs
	output wire ready,				//1 = ready for new commands, 0 = busy
									//All commands except "power down" are ignored when not ready.
									//Power down is queued if needed.

	output reg power_state = 0		//1=on, 0=off
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Sanity check

    initial begin
		if(INTERFACE != "SPI") begin
			$display("SSD1306 only supports INTERFACE=SPI for now");
			$finish;
		end
    end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // SPI interface

	reg			spi_shift_en	= 0;
	wire		spi_shift_done;
	reg[7:0]	spi_tx_data		= 0;

	SPITransceiver #(
		.SAMPLE_EDGE("RISING"),
		.LOCAL_EDGE("NORMAL")
    ) spi_tx (

		.clk(clk),
		.clkdiv(clkdiv),

		.spi_sck(spi_sck),
		.spi_mosi(spi_mosi),
		.spi_miso(1'b0),			//read not hooked up

		.shift_en(spi_shift_en),
		.shift_done(spi_shift_done),
		.tx_data(spi_tx_data),
		.rx_data()
    );

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // SPI chip select control wrapper

    reg			spi_byte_en		= 0;
    reg[2:0]	spi_byte_state	= 0;
    reg[2:0]	spi_byte_count	= 0;
    reg			spi_byte_done	= 0;

    //SPI state machine
    always @(posedge clk) begin

		spi_shift_en		<= 0;
		spi_byte_done		<= 0;

		case(spi_byte_state)

			//Wait for command request, then assert CS
			0: begin
				if(spi_byte_en) begin
					spi_cs_n		<= 0;
					spi_byte_state	<= 1;
					spi_byte_count	<= 0;
				end
			end

			//Wait 3 clocks of setup time, then initiate the transfer
			1: begin
				spi_byte_count		<= spi_byte_count + 1'd1;
				if(spi_byte_count == 2) begin
					spi_shift_en	<= 1;
					spi_byte_state	<= 2;
				end
			end

			//Wait for transfer to finish
			2: begin
				if(spi_shift_done) begin
					spi_byte_count	<= 0;
					spi_byte_state	<= 3;
				end
			end

			//Wait 3 clocks of hold time, then deassert CS
			3: begin
				spi_byte_count		<= spi_byte_count + 1'd1;
				if(spi_byte_count == 2) begin
					spi_cs_n		<= 1;
					spi_byte_state	<= 4;
					spi_byte_count	<= 0;
				end
			end

			//Wait 3 clocks of inter-frame gap, then return
			4: begin
				spi_byte_count		<= spi_byte_count + 1'd1;
				if(spi_byte_count == 2) begin
					spi_byte_done	<= 1;
					spi_byte_state	<= 0;
				end
			end

		endcase

    end

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Main state machine

	localparam STATE_OFF			= 8'h00;
	localparam STATE_BOOT_0			= 8'h01;
	localparam STATE_BOOT_1			= 8'h02;
	localparam STATE_BOOT_2			= 8'h03;
	localparam STATE_BOOT_3			= 8'h04;
	localparam STATE_BOOT_4			= 8'h05;
	localparam STATE_BOOT_5			= 8'h06;
	localparam STATE_BOOT_6			= 8'h07;
	localparam STATE_INIT_0			= 8'h08;
	localparam STATE_INIT_1			= 8'h09;
	localparam STATE_INIT_2			= 8'h0a;
	localparam STATE_INIT_3			= 8'h0b;
	localparam STATE_INIT_4			= 8'h0c;
	localparam STATE_WAIT_IDLE		= 8'h0d;
	localparam STATE_IDLE			= 8'h0e;
	localparam STATE_SHUTDOWN_0		= 8'h0f;
	localparam STATE_SHUTDOWN_1		= 8'h10;
	localparam STATE_SHUTDOWN_2		= 8'h11;
	localparam STATE_REFRESH_0		= 8'h12;
	localparam STATE_REFRESH_1		= 8'h13;
	localparam STATE_REFRESH_2		= 8'h14;
	localparam STATE_REFRESH_3		= 8'h15;

	reg[7:0]	state			= 0;
	reg[23:0]	count			= 0;

	reg[2:0]	page_addr		= 0;

	reg powerdown_pending		= 0;

	assign ready = (state == STATE_IDLE) || (state == STATE_OFF);

    always @(posedge clk) begin

		spi_byte_en				<= 0;

		if(powerdown)
			powerdown_pending	<= 1;

		case(state)

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// OFF

			STATE_OFF: begin

				power_state		<= 0;

				if(powerup) begin
					vdd_en_n	<= 0;

					count		<= 0;
					state		<= STATE_BOOT_0;

				end
			end	//end STATE_OFF

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// BOOT: power etc initialization

			//Give power rails ~1 ms to stabilize, then turn the display off
			STATE_BOOT_0: begin
				count			<= count + 1'h1;
				if(count == 24'h01ffff) begin
					spi_tx_data		<= 8'hae;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_BOOT_1;
				end
			end	//end STATE_BOOT_0

			//Wait for command to finish, then strobe reset for ~1 ms
			STATE_BOOT_1: begin
				if(spi_byte_done) begin
					rst_out_n		<= 0;
					count			<= 0;
					state			<= STATE_BOOT_2;
				end
			end	//end STATE_BOOT_1

			//When reset finishes, set the charge pump and pre-charge period
			STATE_BOOT_2: begin
				count			<= count + 1'h1;
				if(count == 24'h01ffff) begin
					rst_out_n		<= 1;

					spi_tx_data		<= 8'h8d;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_BOOT_3;
				end
			end	//end STATE_BOOT_2

			STATE_BOOT_3: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'h14;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_BOOT_4;
				end
			end	//end STATE_BOOT_3

			STATE_BOOT_4: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'hd9;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_BOOT_5;
				end
			end	//end STATE_BOOT_4

			STATE_BOOT_5: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'hf1;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_BOOT_6;
				end
			end	//end STATE_BOOT_5

			//When the last send finishes, turn on Vbat and wait ~100 ms
			STATE_BOOT_6: begin
				if(spi_byte_done) begin
					vbat_en_n		<= 0;
					count			<= 0;
					state			<= STATE_INIT_0;
				end
			end	//end STATE_BOOT_6

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// INIT: set up display addressing etc

			//TODO: A lot of this config is panel specific, should we have a table or something??

			//spi_tx_data		<= 8'ha5;	//display solid white

			//After Vbat stabilizes, configure stuff.
			//Set column mapping
			STATE_INIT_0: begin
				count				<= count + 1'h1;
				if(count == 24'hbfffff) begin
					spi_tx_data		<= 8'hA1;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_INIT_1;
				end
			end	//end STATE_INIT_0

			//Set row mapping
			STATE_INIT_1: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'hC8;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_INIT_2;
				end
			end	//end STATE_INIT_1

			//Select sequential COM scan configuration with left/right remap
			STATE_INIT_2: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'hDA;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_INIT_3;
				end
			end	//end STATE_INIT_2

			STATE_INIT_3: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'h20;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_INIT_4;
				end
			end	//end STATE_INIT_3

			//Turn the actual display on
			STATE_INIT_4: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'hAF;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_WAIT_IDLE;
				end
			end	//end STATE_INIT_4

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// WAIT: go to idle after current txn finishes

			STATE_WAIT_IDLE: begin
				if(spi_byte_done)
					state			<= STATE_IDLE;
			end	//end STATE_WAIT_IDLE

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// IDLE: Wait for something to happen

			STATE_IDLE: begin

				power_state					<= 1;

				//If we were asked to shut down, do that
				if(powerdown_pending) begin
					powerdown_pending		<= 0;
					state					<= STATE_SHUTDOWN_0;
				end

				//If asked to refresh the display, do that
				else if(refresh) begin
					page_addr				<= 0;
					state					<= STATE_REFRESH_0;
				end

			end	//end STATE_IDLE

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// REFRESH: Update the display

			//Block-based raster scan: 8 pixels high left to right, then next block
			//Each byte is one pixel wide and 8 high.

			//Send row pointer
			STATE_REFRESH_0: begin
				spi_tx_data		<= {4'hB, 1'b0, page_addr[2:0]};
				spi_byte_en		<= 1;
				cmd_n			<= 0;
				state			<= STATE_REFRESH_1;
			end	//end STATE_REFRESH_0

			//Col addr low = 0
			STATE_REFRESH_1: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'h00;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_REFRESH_2;
				end
			end	//end STATE_REFRESH_1

			//Col addr high = 0
			STATE_REFRESH_2: begin
				if(spi_byte_done) begin
					spi_tx_data		<= 8'h10;
					spi_byte_en		<= 1;
					cmd_n			<= 0;
					state			<= STATE_REFRESH_3;
					count			<= 0;
				end
			end	//end STATE_REFRESH_2

			//Write alternating 1s and 0s to the display
			STATE_REFRESH_3: begin
				if(spi_byte_done) begin

					spi_tx_data		<= 8'hf0;
					cmd_n			<= 1;

					count			<= count + 1'h1;

					//If done with this page, move to the next page
					if(count == 128) begin

						//If we wrote the last page we're done (TODO: handle 64-pixel high displays)
						if(page_addr == 3)
							state		<= STATE_IDLE;

						//Nope, more pages to go still
						else begin
							page_addr	<= page_addr + 1'h1;
							state		<= STATE_REFRESH_0;
						end

					end
					else
						spi_byte_en		<= 1;
				end

			end	//end STATE_REFRESH_3

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// SHUTDOWN: turn the display off

			//Send "display off" command
			STATE_SHUTDOWN_0: begin
				spi_tx_data		<= 8'hae;
				spi_byte_en		<= 1;
				cmd_n			<= 0;
				state			<= STATE_SHUTDOWN_1;
			end	//end STATE_SHUTDOWN_0

			//When send finishes, turn off Vbat
			STATE_SHUTDOWN_1: begin
				if(spi_byte_done) begin
					vbat_en_n	<= 1;
					count		<= 0;
					state		<= STATE_SHUTDOWN_2;
				end
			end	//end STATE_SHUTDOWN_1

			//Wait 100ms then turn off Vdd and reset
			STATE_SHUTDOWN_2: begin
				count			<= count + 1'h1;
				if(count == 24'hbfffff) begin
					vdd_en_n	<= 1;
					state		<= STATE_OFF;
				end
			end	//end STATE_SHUTDOWN_2

		endcase

    end

endmodule
