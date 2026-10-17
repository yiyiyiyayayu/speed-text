#include <stdint.h>
char *NSParse(const char *input);
char *NSFetch(const char *input);
long long NSNewRun(void);
void NSCancelRun(long long id);
void NSEndRun(long long id);
char *NSTest(long long id, const char *config, const char *options);
void NSFree(char *value);
