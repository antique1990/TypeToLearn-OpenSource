#include "CRimeBridge.h"
#include "rime_api.h"
#include "rime_logsink_api.h"
#include <stdlib.h>
#include <string.h>

static RimeApi *api;
static RimeSessionId session;
static char current_schema[80];
static char *results[64];
static int indices[64];
static int full_matches[64];
static int result_count;
static int next_index = -1;
static RimeTraits deployment_traits;
static int deployer_initialized;

int lk_rime_initialize(const char *data, const char *work) {
    if (api) return session != 0;
    api = rime_get_api();
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = data;
    traits.user_data_dir = work;
    traits.app_name = "rime.learnkeyboard";
    traits.log_dir = "";
    traits.min_log_level = 3;
    // No scripting, prediction database, or user input logs.
    static const char *modules[] = {"default", "octagram", "logsink", NULL};
    traits.modules = modules;
    // Deployment happens later, so retain the directory strings beyond the
    // Swift withCString call that initializes this process-wide engine.
    deployment_traits = traits;
    deployment_traits.shared_data_dir = strdup(data);
    deployment_traits.user_data_dir = strdup(work);
    if (!deployment_traits.shared_data_dir || !deployment_traits.user_data_dir) return 0;
    api->setup(&traits);
    RimeModule *module = api->find_module("logsink");
    if (module && module->get_api) {
        RimeLogSinkApi *sink = (RimeLogSinkApi *)module->get_api();
        sink->set_stderr_threshold(RIME_LOGSINK_SILENT);
    }
    api->initialize(&traits);
    session = api->create_session();
    return session != 0;
}

int lk_rime_deploy_schema(const char *schema_file) {
    if (!api || !session || !schema_file || !*schema_file) return 0;
    lk_rime_release_results();
    api->clear_composition(session);
    if (!deployer_initialized) {
        // An explicit engine module list suppresses Rime's default deployer
        // modules. Load its compiler group only when fuzzy data is requested.
        static const char *deployment_modules[] = {"deployer", NULL};
        deployment_traits.modules = deployment_modules;
        api->deployer_initialize(&deployment_traits);
        deployer_initialized = 1;
    }
    int result = api->deploy_schema(schema_file);
    // select_schema must run after deployment, even if the previous request
    // happened to select a schema with the same name.
    current_schema[0] = '\0';
    return result;
}

static int prepare(const char *schema, const char *input) {
    if (!api || !session || strlen(schema) >= sizeof(current_schema)) return 0;
    api->clear_composition(session);
    if (strcmp(current_schema, schema)) {
        if (!api->select_schema(session, schema)) return 0;
        strcpy(current_schema, schema);
    }
    return api->set_input(session, input);
}

void lk_rime_release_results(void) {
    for (int i = 0; i < result_count; ++i) { free(results[i]); results[i] = NULL; }
    result_count = 0;
}

static int normalize(const char *source, char *dest, size_t capacity);

static int covers_input(const char *input, int index, char *reading, int capacity) {
    if (!RIME_API_AVAILABLE(api, highlight_candidate)) return -1;
    // False also means the iterator's valid candidate is already highlighted.
    // In particular, the initial candidate at index zero needs no state change.
    api->highlight_candidate(session, (size_t)index);
    RIME_STRUCT(RimeContext, context);
    if (!api->get_context(session, &context)) return -1;
    int result = -1, end = context.composition.sel_end;
    const char *preedit = context.composition.preedit;
    char prefix[1024], normalized[1024], raw[1024];
    if (preedit && end >= 0 && end < (int)sizeof(prefix) && (size_t)end <= strlen(preedit)) {
        memcpy(prefix, preedit, (size_t)end);
        prefix[end] = '\0';
        int all = normalize(input, raw, sizeof(raw));
        int covered = normalize(prefix, normalized, sizeof(normalized));
        if (all > 0 && covered >= 0) result = !strcmp(raw, normalized);
        if (result == 1 && reading && end < capacity) memcpy(reading, prefix, (size_t)end + 1);
    }
    api->free_context(&context);
    return result;
}

static int query(const char *schema, const char *input, int limit, int singles_only, int start, int classify) {
    lk_rime_release_results();
    next_index = -1;
    if (!prepare(schema, input)) return -1;
    if (limit > 64) limit = 64;
    RimeCandidateListIterator it = {0};
    if (!api->candidate_list_from_index(session, &it, start)) return 0;
    while (result_count < limit && api->candidate_list_next(&it)) {
        if (!it.candidate.text || !*it.candidate.text) continue;
        if (singles_only) {
            int scalars = 0;
            for (const unsigned char *p = (const unsigned char *)it.candidate.text; *p && scalars < 2; ++p) {
                if ((*p & 0xc0) != 0x80) ++scalars;
            }
            if (scalars != 1) continue;
        }
        results[result_count] = strdup(it.candidate.text);
        indices[result_count] = it.index;
        full_matches[result_count++] = classify ? covers_input(input, it.index, NULL, 0) : -1;
    }
    if (result_count == limit && api->candidate_list_next(&it)) next_index = it.index;
    api->candidate_list_end(&it);
    return result_count;
}
int lk_rime_query(const char *schema, const char *input, int limit) { return query(schema, input, limit, 0, 0, 0); }
int lk_rime_query_singles(const char *schema, const char *input, int limit) { return query(schema, input, limit, 1, 0, 0); }
int lk_rime_query_page(const char *schema, const char *input, int start, int limit) { return query(schema, input, limit, 0, start, 0); }
int lk_rime_query_ranked_page(const char *schema, const char *input, int start, int limit) { return query(schema, input, limit, 0, start, 1); }
int lk_rime_next_index(void) { return next_index; }
const char *lk_rime_text(int offset) { return offset >= 0 && offset < result_count ? results[offset] : NULL; }
int lk_rime_index(int offset) { return offset >= 0 && offset < result_count ? indices[offset] : -1; }
int lk_rime_covers_input(int offset) { return offset >= 0 && offset < result_count ? full_matches[offset] : -1; }

int lk_rime_candidate_covers_input(const char *schema, const char *input, int index, const char *expected) {
    if (index < 0 || !prepare(schema, input)) return -1;
    RimeCandidateListIterator it = {0};
    if (!api->candidate_list_from_index(session, &it, index)) return -1;
    int matches = api->candidate_list_next(&it) && it.index == index && it.candidate.text &&
                  !strcmp(it.candidate.text, expected);
    api->candidate_list_end(&it);
    return matches ? covers_input(input, index, NULL, 0) : -1;
}

int lk_rime_first_reading(const char *schema, const char *input, char *reading, int capacity) {
    if (!reading || capacity <= 0 || !prepare(schema, input)) return 0;
    RimeCandidateListIterator it = {0};
    if (!api->candidate_list_from_index(session, &it, 0)) return 0;
    reading[0] = '\0';
    if (api->candidate_list_next(&it)) covers_input(input, it.index, reading, capacity);
    api->candidate_list_end(&it);
    return reading[0] != '\0';
}

static int normalize(const char *source, char *dest, size_t capacity) {
    size_t n = 0;
    for (; *source; ++source) {
        if (*source == ' ' || *source == '\'') continue;
        if (!((*source >= 'a' && *source <= 'z') || (*source >= '2' && *source <= '9')) || n + 1 >= capacity) return -1;
        dest[n++] = *source;
    }
    dest[n] = 0;
    return (int)n;
}

int lk_rime_consumed(const char *schema, const char *input, int index, const char *expected) {
    if (index < 0 || !prepare(schema, input)) return 0;
    RimeCandidateListIterator it = {0};
    if (!api->candidate_list_from_index(session, &it, index)) return 0;
    int matches = api->candidate_list_next(&it) && it.candidate.text && !strcmp(it.candidate.text, expected);
    api->candidate_list_end(&it);
    if (!matches || !api->select_candidate(session, (size_t)index)) return 0;
    int consumed = 0;
    RIME_STRUCT(RimeCommit, commit);
    if (api->get_commit(session, &commit)) {
        if (commit.text && !strcmp(commit.text, expected)) consumed = (int)strlen(input);
        api->free_commit(&commit);
    } else {
        RIME_STRUCT(RimeContext, context);
        if (api->get_context(session, &context)) {
            // Rime marks the remaining raw syllables after the selected Chinese prefix.
            // Check the actual suffix, rather than guessing from the number of Chinese characters.
            const char *preedit = context.composition.preedit;
            int start = context.composition.sel_start;
            char remaining[1024], raw[1024];
            int all = normalize(input, raw, sizeof(raw));
            int rest = preedit && start >= 0 && (size_t)start <= strlen(preedit)
                ? normalize(preedit + start, remaining, sizeof(remaining)) : -1;
            if (all > 0 && rest >= 0 && rest < all && !strcmp(raw + all - rest, remaining)) {
                int letters = 0;
                for (int i = 0; input[i]; ++i) {
                    if (input[i] != '\'' && input[i] != ' ') ++letters;
                    if (letters == all - rest) { consumed = i + 1; break; }
                }
            }
            api->free_context(&context);
        }
    }
    api->clear_composition(session);
    return consumed;
}
