#include "program.h"

#include <stdlib.h>

void compiled_program_init(CompiledProgram *prog) {
    prog->functions    = NULL;
    prog->count        = 0;
    prog->structs      = NULL;
    prog->struct_count = 0;
    prog->main_index   = -1;
}





void compiled_program_free(CompiledProgram *prog) {
    for (int i = 0; i < prog->count; i++) {
        free(prog->functions[i].name);
        chunk_free(&prog->functions[i].chunk);
    }
    free(prog->functions);
    for (int i = 0; i < prog->struct_count; i++) {
        free(prog->structs[i].name);
        free(prog->structs[i].offset);        // per-field layout, sized to field_count (field dimension)
        free(prog->structs[i].kind);
        free(prog->structs[i].field_struct);
    }
    free(prog->structs);
    compiled_program_init(prog);
}
