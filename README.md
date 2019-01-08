# branch_predictors
A set of branch predictors for RISC cores with a configurable number of cache entries (intended for 32-bit instructions). Supports branches with and without delay slots (therefore compatible with ISAs such as MicroBlaze). Synthesizeable on FPGA.

These branch predictors were intended for a 5 stage RISC core, where prediction takes place in IF and ID (1st and 2nd stage), and branch resolution takes place in EX (3rd stage). It should however be compatible with designs where branch resolution occurs in later stages.

Predictions and corrections are performed using non-synchronous logic. For bimodal and correlating predictors specifically, prediction state changes occur synchronously.

# Port interface
`predictor_bits`: sets the number of cache entries (branches stored). Total number of entries equals 2^(predictor_bits).
`index`: sets the number of lowest significant bits to ignore in the PC. Usually set to 2, but should be changed for ISAs where PC does not increment by 4.

`clk`, `rst`: Your clock and reset signals.
`pc_if`: PC in IF stage.
`pc_id`: PC in ID stage.
`pc_ex`: PC in EX stage.
`is_branch`: 1-bit signal from EX stage, set high if instruction in EX is a branch (Asserting this signal high for unconditional branches will make the predictor store unconditional branches).
`branch_result`: The result of the branch from EX stage (should be set high if the branch should be taken).
`branch_target`: The target of the branch from EX stage.
`branch_delay`: 1-bit signal from EX stage, set high if the branch has a delay slot

`prediction`: 1-bit output set high if predict taken. Should be sent to your multiplexer that selects the next PC.
`prediction_target`: Target of predicted branch.
`correction`: 2-bit signal for making corrections to incorrect predictions. Normally at "00", will be set to "01" if predicted branch not taken, but should have been taken, "10" if predicted branch taken, but should not have been taken. Should be sent to your correction multiplexer that selects next PC.
`prediction_has_delay_slot`: 1-bit output set high if the predicted branch has a delay slot. 

# Functionality
Branches without delay slots should be predicted in the IF stage. For branches with delay slots, prediction occurs when the branch instruction reaches ID stage. This prevents the delay slot instruction from being overwritten.


