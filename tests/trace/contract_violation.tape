error[postcondition_failed]: postcondition failed in 'half' (ensures, line 5)
  --> tests/trace/contract_violation.em:5:32 (in half)
  route:  half (line 5) <- main (line 11)
{"fn":"main","ip":0,"op":"CONST","line":11,"stack":[]}
{"fn":"main","ip":2,"op":"CALL","line":11,"stack":[7]}
{"fn":"half","ip":0,"op":"GET_LOCAL","line":7,"stack":[7]}
{"fn":"half","ip":2,"op":"CONST","line":7,"stack":[7,7]}
{"fn":"half","ip":4,"op":"DIV","line":7,"stack":[7,7,2]}
{"fn":"half","ip":6,"op":"GET_LOCAL","line":5,"stack":[7,3]}
{"fn":"half","ip":8,"op":"GET_LOCAL","line":5,"stack":[7,3,3]}
{"fn":"half","ip":10,"op":"ADD","line":5,"stack":[7,3,3,3]}
{"fn":"half","ip":12,"op":"GET_LOCAL","line":5,"stack":[7,3,6]}
{"fn":"half","ip":14,"op":"EQ","line":5,"stack":[7,3,6,7]}
{"fn":"half","ip":15,"op":"CONTRACT_CHECK","line":5,"stack":[7,3,0]}
{"event":"contract_violation","fn":"half","line":5,"detail":"postcondition failed in 'half' (ensures, line 5)","stack":[7,3]}
