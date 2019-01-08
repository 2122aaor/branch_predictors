library IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
--USE IEEE.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- this file contains a configurable #entries, direct-mapped bimodal correlating predictor (2 bit global history)
-- it consists of a branch history table and a branch target buffer
-- this setup assumes that the branch target and identification of a branch instruction based on opcode cannot be performed in IF stage
-- therefore, a prediction is only made for branch instructions that have been previously encountered (has a cache entry based on PC)
-- in all other cases, this predictor will default to branch not taken

--the setup currently assumes that branch resolution occurs in the EX stage
--the setup has been designed to accomodate branches with and without delay slots
--for branches without delay slots, it is assumed that prediction is done in IF
--for branches with delay slots, it is assumed that prediction is done in ID
--the current setup will also store unconditional branches. Correction logic is in place for when the branch target is wrong

--Aaron Lai
 
entity bp_correlating is
	generic (
        predictor_bits : natural := 8; -- 2^(predictor_bits) = number of cache entries
        index : natural := 2 --how many LSB bits of the PC to ignore, usually set to 2, but set to 0 for sh4
    );
    
	Port ( 
		clk		: in  STD_LOGIC;
		rst		: in  STD_LOGIC;
        --input ports
        pc_if   : in std_logic_vector(31 downto 0); --PC in IF stage
        pc_id   : in std_logic_vector(31 downto 0); --PC in ID stage
        pc_ex   : in std_logic_vector(31 downto 0); --PC in EX stage
        
        is_branch   : in std_logic; --binary signal that identifies the instruction in EX to be a branch
        branch_result : in std_logic; --branch result from EX stage
        branch_target : in std_logic_vector(31 downto 0); --branch target from ex
        --output ports
        prediction : out std_logic; --select signal to mux_predict
		prediction_has_delay_slot : out std_logic; --driven high when predicted branch has a delay slot (used for superscalar issue logic in some architectures)
        prediction_target : out std_logic_vector(31 downto 0); --feeds into mux_predict
        correction : out std_logic_vector(1 downto 0); --select signal to mux_correct. 00=normal, 01=branch_target, 10=PC+4
        --additional port for mixed delay branches
        branch_delay : in std_logic_vector(0 downto 0)
        
	);
end bp_correlating;
 
architecture Behavioral of bp_correlating is

constant index_lbound : integer := index - 1;

--record for cache entry type
type cache_entry is record
    tag : std_logic_vector(31 downto index); --store the PC of the branch instruction
    target : std_logic_vector(31 downto 0); --store the target for that branch instruction
    --prediction_bits : std_logic_vector(1 downto 0); --the prediction bits
    delay_bit : std_logic_vector(0 downto 0); --used as the use bit in the clock replacement algorithm
end record;

constant clear_entry : cache_entry := (tag => (others => '0'),
                              target => (others => '0'),
                              --prediction_bits => (others => '0'),
                              delay_bit => (others => '0'));
                              

constant cache_depth : natural := 2 ** predictor_bits;
type cache_array is array (0 to (cache_depth - 1)) of cache_entry;
signal cache_data : cache_array;

type global is array (0 to 3) of std_logic_vector(1 downto 0);
type predictor_table is array (0 to (cache_depth - 1)) of global;
signal branch_predictor_table : predictor_table := (others => (others => (others => '0')));
signal global_last : std_logic_vector(1 downto 0) := "00";

         

--constants for prediction system
constant SNT : std_logic_vector(1 downto 0) := "00"; --"strongly not taken"
constant WNT : std_logic_vector(1 downto 0) := "01"; --"weakly not taken"
constant ST  : std_logic_vector(1 downto 0) := "11"; --"strong taken"
constant WT  : std_logic_vector(1 downto 0) := "10"; --"weakly taken"

--constants for correction
constant sel0 : std_logic_vector(1 downto 0) := "00"; --default case, prediction was correct
constant sel1 : std_logic_vector(1 downto 0) := "01"; --predicted branch not taken, but should have been taken
constant sel2 : std_logic_vector(1 downto 0) := "10"; --predicted branch taken, but should not have been taken

 
begin


--process for making predictions
prediction_process : process (pc_if, pc_id, cache_data, branch_predictor_table, global_last, is_branch)
begin
    
    
    if (pc_if(31 downto index) = cache_data(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index)))).tag) AND (cache_data(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index)))).delay_bit = "0") then
              
        prediction <= branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)))(1);
        prediction_target <= cache_data(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index)))).target;
		prediction_has_delay_slot <= cache_data(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index)))).delay_bit(0);
    
    elsif (pc_id(31 downto index) = cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).tag) AND (cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).delay_bit = "1") then       
        
        prediction <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)))(1);
        prediction_target <= cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).target;
		prediction_has_delay_slot <= cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).delay_bit(0);
      
    else  
        prediction <= '0';
        prediction_target <= (others => '0');
		prediction_has_delay_slot <= '0';
    end if;
    
    
end process;


--process for making corrections
correction_output: process (is_branch, pc_ex, branch_result, cache_data, global_last, branch_predictor_table, branch_target)
begin
    
    if (is_branch = '1') then
        
        if (pc_ex(31 downto index) = cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).tag) then
        
            if (branch_target = cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).target) then
            
                case branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) is
                
                    when SNT =>
                        if branch_result = '1' then
                            correction <= sel1;                       
                        else
                            correction <= sel0;                      
                        end if;
                    when WNT =>
                        if branch_result = '1' then
                            correction <= sel1;                     
                        else
                            correction <= sel0;
                        end if;
                    when ST =>
                        if branch_result = '1' then
                            correction <= sel0;
                        else
                            correction <= sel2;
                        end if;
                    when WT =>
                        if branch_result = '1' then
                            correction <= sel0;
                        else
                            correction <= sel2;
                        end if;
                    when others =>
                            
                end case;
            else
                --unconditional branch with incorrect target
                correction <= sel1;
            end if;
            
        else --branch is not in the cache
            if branch_result = '1' then
                correction <= sel1;
            else
                correction <= sel0;
            end if;     
        end if;
    else
        correction <= sel0;
    end if;                        

end process;



--state changes for corrections
correction_statechange: PROCESS (clk, rst)
BEGIN
    
    if rst = '1' then
        branch_predictor_table <= (others => (others => (others => '0')));
        cache_data <= (others => clear_entry);
        global_last <= "00";
        
    elsif rising_edge(clk) then
        if (is_branch = '1') then
            --entry already in cache
            
            if (pc_ex(31 downto index) = cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).tag) then
                
                --unconditional branch with incorrect stored target, update the target
                if (branch_target /= cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).target) then
                    cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).target <= branch_target;
                end if;
                
                case branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) is
                    when SNT =>
                        if branch_result = '1' then
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= WNT;
                        else
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= SNT;
                        end if;
                    when WNT =>
                        if branch_result = '1' then
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= ST;
                        else
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= SNT;
                        end if;
                    when ST =>
                        if branch_result = '1' then
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= ST;
                        else
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= WT;
                        end if;
                    when WT =>
                        if branch_result = '1' then

                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= ST;
                        else
                            
                            branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= SNT;
                        end if;
                    when others =>
                        
                end case;
                
            else --make a new entry in the cache
                if branch_result = '1' then
                    cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).tag <= pc_ex(31 downto index);
                    cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).target <= branch_target;
                    cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).delay_bit <= branch_delay;
                    --cache_data(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index)))).prediction_bits <= WT;
                    
                    branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= WT;
                    branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "01"))) <= WT;
                    branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "10"))) <= WT;
                    branch_predictor_table(to_integer(unsigned(pc_ex((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "11"))) <= WT;
                    
                    
                        
                end if;
            end if;
            
            global_last(1) <= global_last(0);
            if branch_result = '1' then
                global_last(0) <= '1';
            else
                global_last(0) <= '0';
            end if;
            
            --the following 3 if statements perform "global cloning". This prevents the issue of concurrent branches interfering with the correction logic.
            if (pc_if(31 downto index) = cache_data(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index)))).tag) AND (cache_data(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index)))).delay_bit = "0") then
                
                branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "01"))) <= branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "10"))) <= branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "11"))) <= branch_predictor_table(to_integer(unsigned(pc_if((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
            end if;
            if (pc_id(31 downto index) = cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).tag) AND (cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).delay_bit = "1") then
                
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "01"))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "10"))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "11"))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
            end if;
            if (pc_id(31 downto index) = cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).tag) AND (cache_data(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index)))).delay_bit = "0") then
                
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "01"))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "10"))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
                branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last + "11"))) <= branch_predictor_table(to_integer(unsigned(pc_id((predictor_bits + index_lbound) downto index))))(to_integer(unsigned(global_last)));
            end if;
                
        else
        
        end if;
    end if;                                                                         
    
END PROCESS;


    
end Behavioral;