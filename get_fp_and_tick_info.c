#include <stdio.h>
#include <sys/time.h>

#define SEC_IN_USEC 1000000L
#define N_ITERS 1000

int main() {
    printf("Size of float: %zu bytes\n", sizeof(float));
    printf("Size of double: %zu bytes\n", sizeof(double));

    struct timeval t1, t2;
    long min_diff = SEC_IN_USEC;

    gettimeofday(&t1, NULL);
    for (int i = 0; i < N_ITERS; i++) {
        if (gettimeofday(&t2, NULL) != 0) {
            printf("gettimeofday error");
            return 0;
        }
        long diff = (t2.tv_sec - t1.tv_sec) * SEC_IN_USEC + (t2.tv_usec - t1.tv_usec);
        printf("%lu\n", diff);
        if (diff > 0 && diff < min_diff) {
            min_diff = diff;
        }
        t1 = t2;
    }

    printf("Estimated clock tick granularity: %ld microseconds\n", min_diff);
    return 0;
}