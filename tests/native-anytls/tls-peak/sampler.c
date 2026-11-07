// One-shot test observer: no production configuration or node management.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
static long field(const char *file,const char *name){FILE*f=fopen(file,"r");if(!f)return -1;char b[1024],k[128];long v,result=-1;while(fgets(b,sizeof b,f)){if(sscanf(b,"%127s %ld",k,&v)==2&&!strcmp(k,name)){result=v;break;}}fclose(f);return result;}
static unsigned long long ticks(int pid){char p[96],b[2048];snprintf(p,sizeof p,"/proc/%d/stat",pid);FILE*f=fopen(p,"r");if(!f)return 0;if(!fgets(b,sizeof b,f)){fclose(f);return 0;}fclose(f);char*s=strrchr(b,')');if(!s)return 0;s+=2;char*save=0,*t=strtok_r(s," ",&save);for(int n=3;t&&n<22;n++)t=strtok_r(0," ",&save);return t?strtoull(t,0,10):0;}
static int owned(int pid,const char*needle){char p[96],b[4096];snprintf(p,sizeof p,"/proc/%d/cmdline",pid);FILE*f=fopen(p,"r");if(!f)return 0;size_t n=fread(b,1,sizeof b-1,f);fclose(f);for(size_t i=0;i<n;i++)if(!b[i])b[i]=' ';b[n]=0;return strstr(b,needle)!=0;}
int main(int argc,char**argv){if(argc==2&&!strcmp(argv[1],"--check-crashlog")){FILE*f=fopen("/dev/mtd3","rb");if(!f)return 4;unsigned char b[4096];unsigned long total=0,nonff=0;size_t n;while(total<524288&&(n=fread(b,1,sizeof b,f))>0){total+=n;for(size_t j=0;j<n;j++)if(b[j]!=255)nonff++;}fclose(f);printf("bytes_read=%lu non_erased_bytes=%lu\n",total,nonff);return total==524288?0:4;}if(argc!=3)return 2;int client=atoi(argv[1]),xray=atoi(argv[2]);if(client<2||xray<2||!owned(client,"/tmp/fss-tls-peak/client")||!owned(xray,"/tmp/fss-tls-peak/xray.json"))return 2;unsigned long long ct=ticks(client),xt=ticks(xray);char cpath[80],xpath[80];snprintf(cpath,sizeof cpath,"/proc/%d/status",client);snprintf(xpath,sizeof xpath,"/proc/%d/status",xray);
 int kmsg=open("/dev/kmsg",O_RDONLY|O_NONBLOCK); if(kmsg>=0)lseek(kmsg,0,SEEK_END); fprintf(stderr,"kernel_event_reader=%s\n",kmsg>=0?"enabled":"unavailable");
 puts("uptime,available_kib,client_rss_kib,client_hwm_kib,client_threads,xray_rss_kib,xray_hwm_kib,oom_kill,pgmajfault");fflush(stdout);
 for(int i=0;i<3600;i++){char kb[8192];ssize_t got;while(kmsg>=0&&(got=read(kmsg,kb,sizeof kb-1))>0){kb[got]=0;if(strstr(kb,"panic")||strstr(kb,"oom")||strstr(kb,"Out of memory")||strstr(kb,"watchdog")||strstr(kb,"Oops")||strstr(kb,"BUG:")||strstr(kb,"allocation failure")){fprintf(stderr,"kernel_event:%s",kb);fflush(stderr);}}struct timespec ts;clock_gettime(CLOCK_BOOTTIME,&ts);long available=field("/proc/meminfo","MemAvailable:");printf("%.3f,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld\n",ts.tv_sec+ts.tv_nsec/1e9,available,field(cpath,"VmRSS:"),field(cpath,"VmHWM:"),field(cpath,"Threads:"),field(xpath,"VmRSS:"),field(xpath,"VmHWM:"),field("/proc/vmstat","oom_kill"),field("/proc/vmstat","pgmajfault"));fflush(stdout);
 if(available<49152){fprintf(stderr,"ABORT available below 48 MiB\n");if(ticks(client)==ct&&owned(client,"/tmp/fss-tls-peak/client"))kill(client,SIGTERM);if(ticks(xray)==xt&&owned(xray,"/tmp/fss-tls-peak/xray.json"))kill(xray,SIGTERM);return 3;}if(ticks(client)!=ct||ticks(xray)!=xt)return 1;struct timespec pause={0,250000000};nanosleep(&pause,0);}
 return 0;}
