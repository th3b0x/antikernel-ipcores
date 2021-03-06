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
	@file
	@author Andrew D. Zonenberg
	@brief On-die sensors for Xilinx 7-series devices
 */
module OnDieSensors_7series #(
	parameter EXT_IN_ENABLE = 16'h0
)(

	//max 250 MHz across speed grades
	input wire			clk,

	input wire[15:0]	vin_p,
	input wire[15:0]	vin_n,

	//Sensor values
	//All are 8.8 fixed point, for example 16'h0480 = 4.5 units.
	//This can also be modeled as one LSB = 1/256 of a volt or deg C
	output logic[15:0]	die_temp		= 0,	//Die temp (degC)
	output logic[15:0]	volt_core		= 0,	//VCCINT
	output logic[15:0]	volt_ram		= 0,	//VCCBRAM
	output logic[15:0]	volt_aux		= 0,	//VCCAUX
	output logic		sensors_update	= 0,

	//External analog input values
	//Full scale = 1V
	output logic[191:0]	ext_in			= 0,	//ADn = n*12 +: 12
	output logic		ext_update		= 0
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// The actual XADC

	logic[15:0]	xadc_din		= 0;
	wire[15:0]	xadc_dout;
	logic[6:0]	xadc_addr		= 0;
	logic		xadc_en			= 0;
	logic		xadc_we			= 0;
	wire		xadc_ready;
	wire[7:0]	xadc_alarm;
	wire		xadc_overheat;
	wire		xadc_busy;
	logic		xadc_reset		= 1;

	XADC #(
		.INIT_40(16'h2000),		//average 16 samples continously
		.INIT_41(16'h20F0),		//continuous sampling mode, calibrate everything
		.INIT_42(16'h0A00),		//Not powered down, DCLK = clk_noc/10
		.INIT_43(16'h0000),		//factory test
		.INIT_44(16'h0000),		//factory test
		.INIT_45(16'h0000),		//factory test
		.INIT_46(16'h0000),		//factory test
		.INIT_47(16'h0000),		//factory test
		.INIT_48(16'h4701),		//VCCBRAM, VCCAUX, VCCINT, temp, cal
		.INIT_49(EXT_IN_ENABLE),//bitmask of enabled external channels
		.INIT_4A(16'h4700),		//do averaging on all selected channels
		.INIT_4B(EXT_IN_ENABLE),//do averaging on all external channels in use
		.INIT_4C(16'h0000),		//internal sensors unipolar
		.INIT_4D(16'h0000),		//external inputs unipolar
		.INIT_4E(16'h0000),		//no additional settling time
		.INIT_4F(16'h0000),		//no additional settling time
		.INIT_50(16'hb5ed),		//temp alarm +85C
		.INIT_51(16'h5999),		//vccint alarm 1.05V
		.INIT_52(16'hA147),		//vccaux alarm 1.89V
		.INIT_53(16'hdddd),		//thermal shutdown at 125C
		.INIT_54(16'ha93a),		//reset temp alarm at 60C
		.INIT_55(16'h5111),		//vccint alarm 0.95V
		.INIT_56(16'h91eb),		//vccaux alarm 1.71V
		.INIT_57(16'hae4e),		//reset thermal shutdown at 70C
		.INIT_58(16'h5999),		//vccbram alarm 1.05V
		//59 - 5b are alarm thresholds for zynq PS, ignored for now
		//TODO: specify them on zynq
		.INIT_5C(16'h5111)		//vccbram alarm 0.95V
	) xadc (
		.DI(xadc_din),
		.DO(xadc_dout),
		.DADDR(xadc_addr),
		.DEN(xadc_en),
		.DWE(xadc_we),
		.DCLK(clk),
		.DRDY(xadc_ready),
		.RESET(xadc_reset),
		.CONVST(1'b0),
		.CONVSTCLK(1'b0),
		.VP(1'b0),
		.VN(1'b0),
		.VAUXP(vin_p),
		.VAUXN(vin_n),
		.ALM(xadc_alarm),
		.OT(xadc_overheat),
		.MUXADDR(),				//no external mux
		.CHANNEL(),
		.EOC(),
		.EOS(),
		.BUSY(xadc_busy),
		.JTAGLOCKED(),			//ignore jtag stuff, we assume its not in use
		.JTAGMODIFIED(),
		.JTAGBUSY()
		);

	//Pipelined multiplier
	logic[15:0] 	mult_a		= 0;
	logic[31:0] 	mult_b		= 0;
	(* MULT_STYLE = "PIPE_BLOCK" *)
	logic[31:0]	mult_out	= 0;
	logic[31:0] 	mult_out2	= 0;
	logic[31:0] 	mult_out3	= 0;
	logic			mult_en		= 0;
	logic			mult_en2	= 0;
	logic			mult_en3	= 0;
	logic			mult_done	= 0;
	always_ff @(posedge clk) begin
		mult_en2	<= mult_en;
		mult_en3	<= mult_en2;
		mult_done	<= mult_en3;
		mult_out	<= mult_a * mult_b;
		mult_out2	<= mult_out;
		mult_out3	<= mult_out2;
	end

	//Combined shift right is 8 bits for fixed point, plus 12 for divide, or 20 bits.
	//This puts the radix point at bit 20, and the least significant fractional bit at bit 12.
	wire[31:0] die_temp_raw = mult_out3[31:12] - 32'h11126;

	logic[3:0] xadc_state = 0;
	logic[9:0] xadc_count = 0;
	always_ff @(posedge clk) begin

		xadc_din		<= 0;
		xadc_en			<= 0;
		xadc_we			<= 0;
		mult_en			<= 0;

		sensors_update	<= 0;
		ext_update		<= 0;

		//Just poll the sensors in a tight loop
		//TODO: Can save some power by waiting a bit in between poll rounds?
		//TODO: Sync to new-data alerts?
		case(xadc_state)

			//Power-up reset
			0: begin
				xadc_reset	<= 1;
				xadc_count	<= xadc_count + 8'h1;
				if(xadc_count == 8'hff)
					xadc_state	<= 1;
			end

			1: begin
				xadc_reset	<= 0;
				xadc_count	<= xadc_count + 8'h1;
				if(xadc_count == 8'hff)
					xadc_state	<= 2;
			end

			//Read temps
			2: begin
				xadc_en		<= 1;
				xadc_addr	<= 16'h0000;
				xadc_state	<= 3;
			end

			//TEMP transfer function:
			//temp = ((ADC * 503.975) / 4096) - 273.15
			//In fixed point, this is ((ADC * 0x1F7.F9) / 4096) - 0x111.26
			3: begin
				if(xadc_ready) begin
					mult_en		<= 1;
					mult_a		<= xadc_dout[15:4];	//ignore four LSBs
					mult_b		<= 32'h1F7F9;
					xadc_state	<= 4;
				end
			end

			//Wait for multiply (do addition combinatorially elsewhere)
			4: begin
				if(mult_done) begin
					die_temp	<= die_temp_raw[15:0];
					xadc_state	<= 5;
				end
			end

			//Read voltages
			5: begin
				if(!xadc_busy) begin

					//Prepare to read next voltage
					if(xadc_addr == 0)		//Just did temp? Read VCCINT
						xadc_addr	<= 1;
					else if(xadc_addr == 1)	//Just did VCCINT? Do VCCAUX
						xadc_addr	<= 2;
					else if(xadc_addr == 2)	//Just did VCCAUX? Do VCCBRAM
						xadc_addr	<= 6;

					//Go read it
					xadc_en			<= 1;
					xadc_state		<= 6;

				end
			end

			//POWER transfer function
			//volt = (ADC * 3) / 4096
			6: begin
				if(xadc_ready) begin
					mult_en		<= 1;
					mult_a		<= xadc_dout[15:4];
					mult_b		<= 3;
					xadc_state	<= 7;
				end
			end

			//Shift right by 12 bits, then add 8 fractional bits for a total shift of 4
			7: begin
				if(mult_done) begin
					case(xadc_addr)
						1:	volt_core	<= mult_out3[19:4];
						2:	volt_aux	<= mult_out3[19:4];
						6:	volt_ram	<= mult_out3[19:4];
					endcase

					//If we read the last one, move on to the external inputs
					if(xadc_addr == 6) begin
						xadc_state		<= 8;
						xadc_addr		<= 16;	//first result register
						sensors_update	<= 1;
					end
					else
						xadc_state	<= 5;

				end
			end

			//Read external inputs (regardless of whether they're enabled, for now)
			8: begin
				if(!xadc_busy) begin
					xadc_en		<= 1;
					xadc_count	<= 0;
					xadc_state	<= 9;
				end
			end

			//Process results
			9: begin
				if(xadc_ready) begin

					//Last one? Stop
					if(xadc_addr[3:0] == 4'hf) begin
						xadc_state	<= 10;
						ext_update	<= 1;
					end

					//No, save this and prepare to read the next one
					else begin
						xadc_addr								<= xadc_addr + 1'h1;
						ext_in[ xadc_addr[3:0] * 12 +: 12 ]		<= xadc_dout[15:4];
					end

				end

				//if we get stuck, abort
				//(not sure why this is happening??)
				xadc_count <= xadc_count + 1;
				if(xadc_count == 1023)
					xadc_state	<= 2;
			end

			//Repeat
			10: begin
				if(!xadc_busy) begin
					xadc_state		<= 2;
				end
			end

		endcase

	end

endmodule
