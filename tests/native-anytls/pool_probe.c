#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int connect_local(int port){int s=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port)};inet_pton(AF_INET,"127.0.0.1",&a.sin_addr);if(connect(s,(struct sockaddr*)&a,sizeof a)){close(s);return -1;}return s;}
static int greeting(int s,int timeout){unsigned char q[]={5,1,0},r[2];if(send(s,q,3,0)!=3)return -1;struct pollfd p={s,POLLIN,0};if(poll(&p,1,timeout)!=1)return 0;return recv(s,r,2,MSG_WAITALL)==2&&r[0]==5&&r[1]==0;}
int main(int argc,char **argv){if(argc<2)return 2;int port=atoi(argv[1]),held[256],n=0,limit=argc>2?atoi(argv[2]):32;double start=now();for(;n<limit;n++){held[n]=connect_local(port);if(held[n]<0||greeting(held[n],1500)!=1){printf("hold_failed=%d\n",n);return 1;}}double fill=now()-start;int extra=connect_local(port);double begin=now();int blocked=greeting(extra,1000);double delay=now()-begin;close(held[0]);held[0]=-1;struct pollfd p={extra,POLLIN,0};double release=now();int ready=poll(&p,1,1500);unsigned char r[2]={0};if(ready==1)recv(extra,r,2,MSG_WAITALL);printf("{\"held\":%d,\"fill_seconds\":%.6f,\"extra_greeting_with_full_pool\":%d,\"blocked_seconds\":%.6f,\"greeting_after_release\":%d,\"release_seconds\":%.6f}\n",limit,fill,blocked,delay,ready==1&&r[0]==5&&r[1]==0,now()-release);close(extra);for(int i=0;i<n;i++)if(held[i]>=0)close(held[i]);return 0;}
