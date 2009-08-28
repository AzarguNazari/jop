library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sc_pack.all;
use work.sc_arbiter_pack.all;
use work.tm_pack.all;
use work.tm_internal_pack.all;

-- TODO filter flash accesses

entity tmif is

generic (
	addr_width		: integer;
	way_bits		: integer
);

port (
	clk					: in std_logic;
	reset				: in std_logic;
	
	--
	--	Commit logic
	--
	
	-- set until transaction finished/aborted
	commit_out_try			: buffer std_logic; -- TODO
	commit_in_allow			: in std_logic;

	--
	--	Commit addresses
	--
	broadcast				: in tm_broadcast_type;

	--
	--	Memory IF to cpu
	--
	sc_out_cpu		: in sc_out_type;
	sc_in_cpu		: out sc_in_type;		
	-- memory access types
	-- TODO more hints about memory access type?

	--
	--	Memory IF to arbiter
	--
	sc_out_arb		: out sc_out_type;
	sc_in_arb		: in sc_in_type;

	--
	--	Rollback exception
	--
	exc_tm_rollback	: out std_logic
		
);

end tmif;

architecture rtl of tmif is

		
	signal state, next_state		: state_type;
	signal nesting_cnt				: nesting_cnt_type;
	signal next_nesting_cnt			: nesting_cnt_type;
		
	signal conflict					: std_logic;
	
	-- set asynchronously
	signal tm_cmd					: tm_cmd_type;
	
	-- TODO
	--signal tm_cmd_valid				: std_logic;
	
	signal start_commit				: std_logic;
	signal committing				: std_logic;
	
	signal read_tag_of				: std_logic;
	signal write_buffer_of			: std_logic;

	signal reset_on_transaction_start 	: std_logic;

	-- filter signals to/from tm module
	signal reset_tm					: std_logic;
	
	signal sc_out_cpu_filtered		: sc_out_type;
	
	signal sc_in_cpu_filtered		: sc_in_type;
	signal sc_out_arb_filtered		: sc_out_type;

	signal processing_tm_cmd		: std_logic;	
	signal next_processing_tm_cmd	: std_logic;
	
	signal next_tm_cmd_rdy_cnt			: unsigned(RDY_CNT_SIZE-1 downto 0);
	signal tm_cmd_rdy_cnt				: unsigned(RDY_CNT_SIZE-1 downto 0);
	


	--
	-- MEMORY ACCESS SELECTOR
	--
	
	type memory_access_mode_type is (
		bypass,
		transactional,
		commit,
		contain
		);
		
	signal memory_access_mode			: memory_access_mode_type;
	signal next_memory_access_mode		: memory_access_mode_type;

begin

	reset_tm <= reset or reset_on_transaction_start;

	cmp_tm: entity work.tm(rtl)
	generic map (
		addr_width => addr_width,
		way_bits => way_bits
	)	
	port map (
		clk => clk,
		reset => reset_tm,
		from_cpu => sc_out_cpu_filtered,
		to_cpu => sc_in_cpu_filtered,
		to_mem => sc_out_arb_filtered,
		from_mem => sc_in_arb,
		
		broadcast => broadcast,
		conflict => conflict,
		
		start_commit => start_commit,
		committing => committing,
		
		read_tag_of => read_tag_of,
		write_buffer_of => write_buffer_of
		);			


	--
	-- TM STATE MACHINE
	--

	sync: process(reset, clk) is
	begin
		if reset = '1' then
			state <= no_transaction;
			nesting_cnt <= (others => '0');
			
			processing_tm_cmd <= '0';
			
			--tm_cmd <= none;
			
			tm_cmd_rdy_cnt <= "00";
		elsif rising_edge(clk) then
			state <= next_state;
			nesting_cnt <= next_nesting_cnt;
			
			processing_tm_cmd <= next_processing_tm_cmd;
			tm_cmd_rdy_cnt <= next_tm_cmd_rdy_cnt;			
		end if;
	end process sync;
	
	gen_tm_cmd: process (sc_out_cpu) is
	begin
		tm_cmd <= none;			
		
		-- TODO
		if sc_out_cpu.wr = '1' then
			if sc_out_cpu.address = TM_MAGIC then
				tm_cmd <= tm_cmd_type'val(to_integer(unsigned(
					sc_out_cpu.wr_data(tm_cmd_raw'range))));
			end if;
		end if;
	end process gen_tm_cmd;	

	
	gen_rdy_cnt_sel: process(commit_out_try, committing, next_tm_cmd_rdy_cnt, 
		processing_tm_cmd, tm_cmd) is
	begin
		next_processing_tm_cmd <= processing_tm_cmd;	
	
		if processing_tm_cmd = '0' then
			if tm_cmd /= none then
				next_processing_tm_cmd <= '1';
			end if;
		else
			-- TODO
			if next_tm_cmd_rdy_cnt = "00" and 
				(committing = '0' and commit_out_try = '0') then
				next_processing_tm_cmd <= '0';
			end if;
		end if;
	end process gen_rdy_cnt_sel;
	

	
	nesting_cnt_process: process(nesting_cnt, tm_cmd) is
	begin	
		case tm_cmd is
			when start_transaction =>
				next_nesting_cnt <= nesting_cnt + 1;
			when end_transaction =>
				next_nesting_cnt <= nesting_cnt - 1;
			when early_commit | none =>
				next_nesting_cnt <= nesting_cnt;
			when aborted =>
				next_nesting_cnt <= (others => '0');				
		end case;				
	end process nesting_cnt_process; 

	-- sets next_state, exc_tm_rollback, tm_cmd_rdy_cnt, start_commit
	state_machine: process(state, tm_cmd, nesting_cnt, commit_in_allow,
		conflict, write_buffer_of, read_tag_of, start_commit, committing) is
	begin
		next_state <= state;
		exc_tm_rollback <= '0';
		next_tm_cmd_rdy_cnt <= "00";
		start_commit <= '0';
		
		reset_on_transaction_start <= '0';
		
		case state is
			when no_transaction =>
				if tm_cmd = start_transaction then
						next_state <= start_normal_transaction;
						-- TODO not needed if set asynchronously
						next_tm_cmd_rdy_cnt <= "01";
				end if;
				
			when start_normal_transaction =>
				next_state <= normal_transaction;
				reset_on_transaction_start <= '1';
			when normal_transaction =>
				case tm_cmd is
					when end_transaction =>
						if nesting_cnt = nesting_cnt_type'(0 => '1', others => '0') then
							next_state <= commit_wait_token;
							next_tm_cmd_rdy_cnt <= "11";
						end if;
					when early_commit =>
						next_state <= early_commit_wait_token;
						next_tm_cmd_rdy_cnt <= "11";
					when others => 
						null;
				end case;						
				
				if read_tag_of = '1' or write_buffer_of = '1' then
					next_state <= early_commit_wait_token;
				end if;
				
				if conflict = '1' then
					next_state <= rollback_signal;
				end if;
			when commit_wait_token =>
				next_tm_cmd_rdy_cnt <= "11";
			
				if commit_in_allow = '1' then
					next_state <= commit;
					start_commit <= '1';
				end if;
			
				if conflict = '1' then
					next_state <= rollback_signal;
					start_commit <= '0';
				end if;
			when commit =>
				next_tm_cmd_rdy_cnt <= "11";
				
				-- TODO check condition
				if start_commit = '0' and committing = '0' then
					-- TODO which state?
					next_state <= end_transaction;
				end if;
				
				
			when early_commit_wait_token =>
				if commit_in_allow = '1' then
					next_state <= early_commit;
					start_commit <= '1';
				end if;
				
				if conflict = '1' then
					next_state <= rollback_signal;
					start_commit <= '0';
				end if;
			when early_commit =>
				-- TODO check condition
				if start_commit = '0' and committing = '0' then
					next_state <= early_committed_transaction;
				end if;
			when early_committed_transaction =>
				case tm_cmd is
					when end_transaction =>
						if nesting_cnt = 
							nesting_cnt_type'(0 => '1', others => '0') then
							next_state <= end_transaction;
							next_tm_cmd_rdy_cnt <= "10"; -- TODO
						end if;
					when others =>
						null;
				end case;
				
			when end_transaction =>
				-- TODO
				next_state <= no_transaction;
				-- TODO not needed if set asynchronously
				next_tm_cmd_rdy_cnt <= "01";
				
			when rollback_signal =>
				-- TODO this is set asynchronously
				exc_tm_rollback <= '1';
				-- TODO
				next_state <= rollback_wait;
				
			when rollback_wait =>
				-- TODO make sure all other commands ignored
				if tm_cmd = aborted then
					next_state <= no_transaction;
				end if;
			
		end case;
	end process state_machine;
	
	-- TODO register?
	commit_out_try <= '1' 
		when state = commit_wait_token or state = early_commit_wait_token or
		state = early_committed_transaction or state = commit
		-- or state = end_transaction
		else '0';
		
	
	
	
	--
	-- MEMORY ACCESS SELECTOR
	--

	-- TODO
	with next_state select
		next_memory_access_mode <= 
			bypass when no_transaction | start_normal_transaction |
				early_committed_transaction | end_transaction, 
			transactional when normal_transaction,
			commit when commit_wait_token | commit | 
				early_commit_wait_token | early_commit,
			contain when rollback_signal | rollback_wait;						


	gen_memory_access_mode: process (clk, reset) is
	begin
	    if reset = '1' then
	    	memory_access_mode <= bypass;
	    elsif rising_edge(clk) then
	    	memory_access_mode <= next_memory_access_mode;
	    end if;
	end process gen_memory_access_mode;



	-- sets sc_out_cpu_filtered, sc_out_arb, sc_in_cpu
	-- TODO this is not well thought-out	
	process(memory_access_mode, processing_tm_cmd, sc_in_arb, 
		sc_in_cpu_filtered, sc_out_arb_filtered, sc_out_cpu, tm_cmd, 
		tm_cmd_rdy_cnt) is
	begin
		sc_out_cpu_filtered <= sc_out_cpu;
		sc_out_arb <= sc_out_cpu;
		sc_in_cpu <= sc_in_cpu_filtered;
	
		case memory_access_mode is
			when bypass =>				
				 sc_in_cpu <= sc_in_arb;
							
			when transactional =>
				sc_out_arb.wr <= '0';
				
			when commit =>
				sc_out_arb <= sc_out_arb_filtered;
			
			when contain =>
				sc_out_cpu_filtered.wr <= '0';
				sc_out_cpu_filtered.rd <= '0'; -- TODO reads?
				
				sc_out_arb.wr <= '0';
				
				sc_in_cpu <= (
					rdy_cnt => (others => '0'),
					rd_data => (others => '0'));
		end case;
		
		-- overrides when executing TM command
		
		-- TODO define processing_tm_cmd
		if tm_cmd /= none then
			sc_out_cpu_filtered.wr <= '0';
			sc_out_arb.wr <= '0';
		end if;					
		
		-- TODO
		if processing_tm_cmd = '1' then 
		-- TODO and (committing = '0' and commit_out_try = '0') then									
			sc_in_cpu.rdy_cnt <= tm_cmd_rdy_cnt;
		end if;		
	end process; 
	
	

end rtl;
