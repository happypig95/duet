#include <pthread.h>

int x;
int y;
int b1, b2; // N boolean flags
int X; //variable to test mutual exclusion

void* thread1(void* arg) {
  while (1) {
    b1 = 1;
    x = 1;
    if (y != 0) {
      b1 = 0;
      while (y != 0) {};
      continue;
    }
    y = 1;
    if (x != 1) {
      b1 = 0;
      while (b2 >= 1) {};
      if (y != 1) {
	while (y != 0) {};
	continue;
      }
    }
    break;
  }
  // begin: critical section
  X = 0;
  assert(X <= 0);
  // end: critical section
  y = 0;
  b1 = 0;
  return NULL;
}

void* thread2(void* arg) {
  while (1) {
    b2 = 1;
    x = 2;
    if (y != 0) {
      b2 = 0;
      while (y != 0) {};
      continue;
    }
    y = 2;
    if (x != 2) {
      b2 = 0;
      while (b1 >= 1) {};
      if (y != 2) {
	while (y != 0) {};
	continue;
      }
    }
    break;
  }
  // begin: critical section
  X = 1;
  assert(X >= 1);
  // end: critical section
  y = 0;
  b2 = 0;
  return NULL;
}

void main() {
  pthread_t t1, t2;

  pthread_create(&t1, NULL, thread1, NULL);
  pthread_create(&t2, NULL, thread2, NULL);
}
