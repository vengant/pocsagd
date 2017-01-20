#!/usr/bin/perl

use Device::SerialPort;
use strict;
use warnings;
use Proc::Daemon;
use POSIX qw(strftime);
use Proc::Daemon;
use File::Pid;
use WebSphere::MQTT::Client;
use Data::Dumper;
use Switch;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);

        my $dev="/dev/pocsagmodem";
        my $baudrate=1; #0 for 512, 1 for 1200, 2 for 2400
        my $invert=1;
        my $msgtype="A";
        my $logfile="/var/log/pocsagd.log";
        my $beacon="DE RA1AIE HAM RADIO PAGING K";
        my $server="express.dstar.su";
        my $clientid="spb-page-kolpino";
        my $pbeacon="DE RA1AIE HAM RADIO PAGING KOLPINO";
        my $arbitrage="http://www.dstar.su/express/reserve.php";
        my $call="RA1AIE-3";
        my $mqtt = new WebSphere::MQTT::Client(
          Hostname => $server,
          Port => 1883,
          Debug => 0,
          keep_alive => 600,
          clientid => $clientid,
        );
        my $port = new Device::SerialPort($dev);
        my $lasttx=time();

        open(my $log, '>', $logfile) or die "Can't access '$logfile' $!";
        $log->autoflush(1);

        my $continue = 1;
        $SIG{TERM} = sub { $continue = 0 };

        my $pidfile = File::Pid->new({file => '/var/run/pocsagd.pid',});
        $pidfile->write;

sub DetectDevice {
        my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();

        print $log "$now Opening serial port $dev... \n";

        $port->user_msg("ON");
        $port->baudrate(9600);
        $port->parity("none");
        $port->databits(8);
        $port->stopbits(1);
        $port->handshake("xoff");
        $port->write_settings;

        $port->lookclear;
        sleep 3;
        $now = strftime "%Y-%m-%d %H:%M:%S", localtime();

        my $STALL_DEFAULT=2; # how many seconds to wait for new input

        my $timeout=$STALL_DEFAULT;

        $port->read_char_time(5);     # don't wait for each character
        $port->read_const_time(1000); # 1 second per unfulfilled "read" call

        print $log "$now Checking device... \n";


        my $buffer="";
        my $flag=1;
        my $byte;
        $port->write("v\r");

        my ($count,$saw)=$port->read(255); # will read _up to_ 255 chars
        ##$saw =~ s/v//ig;

        if (index($saw, "3.25R") != -1) {
          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
          print $log "$now Device found on $dev!\n";
        } else {
          die "$now Device not found on $dev!";
        }

}

sub SubscribeMQTT {
        my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
        print $log "$now Connecting to $server...\n";

        my $res = $mqtt->connect();
        my $counter1 = 0;
        my $counter2 = 0;
        my $cmd;
        while ($res) {
          $counter1++;
          $counter2++;
          if ($counter1 eq 13) {
                $counter1 = 0;
                print $log "$now Sending emergency POCSAG messages...\n";
                $cmd="#$msgtype,$baudrate,$invert,0001116,0,$now ALERT: RASPBERRY NOT CONNECTED TO SERVER FOR 10 MINUTES!";
                PushToControllerEmer($cmd);
                sleep 1;
                $cmd="#$msgtype,$baudrate,$invert,0001111,0,$now ALERT: RASPBERRY NOT CONNECTED TO SERVER FOR 10 MINUTES!";
                PushToControllerEmer($cmd);
          }
          if ($counter2 eq 40) {
                $counter2 = 0;
                print $log "$now Sending emergency CW beacon...\n";
                $cmd="mK K K ALERT!";
                PushToControllerEmer($cmd);
          }
          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
          print $log "$now Failed to connect: $res, retrying after 30 seconds...\n";
          sleep 30;
          $res = $mqtt->connect();
        }

        print $log Dumper( $mqtt );

        sleep 1;
        $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
        print $log "$now status=".$mqtt->status()."\n";

        # Subscribe to topic
        $res = $mqtt->subscribe( 'Express/+' );
        print $log "$now Subscribe result=$res\n";
}

sub RequestPTT {

      my ($interval)=@_;

      my $ua = LWP::UserAgent->new;

      my $req = HTTP::Request->new(POST=>$arbitrage);
      $req->content_type('application/x-www-form-urlencoded');
      $req->content("call=$call&interval=$interval");

      my $resp = $ua->request($req);
      my $result=0;
      if ($resp->is_success) {
          my $message = $resp->decoded_content;
          print $log " Received reply: $message\n";
          if (index($message, "ACCEPTED") != -1) {$result=1;}
      }
      else {
          print $log " HTTP POST error code: ", $resp->code, "\n";
          #print $log "HTTP POST error message: ", $resp->message, "\n";
      }

      return $result;
}

sub WithdrawPTT {

      my $interval=0;

      my $ua = LWP::UserAgent->new;

      my $req = HTTP::Request->new(POST=>$arbitrage);
      $req->content_type('application/x-www-form-urlencoded');
      $req->content("call=$call&interval=$interval");

      my $resp = $ua->request($req);
      my $result=0;
      if ($resp->is_success) {
          my $message = $resp->decoded_content;
          print $log " Received reply: $message\n\n";
      }
      else {
          print $log " HTTP POST error code: ", $resp->code, "\n\n";
          #print $log "HTTP POST error message: ", $resp->message, "\n";
      }
}

sub CheckControllerStatus {
        my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
        #print $log "$now Checking controller status...\n";
        $port->write("s\r");
        my $clear=0;
        my $flag=1;
        my $read="";
        while($flag) {
          my $byte=$port->read(1);
          my $ord=ord($byte);
          if ($byte ne "\r") {$read="$read$byte";}
          if ($ord eq 0) {$flag=0;}
       }
       my $ptt=substr($read,0,1);
       my $status=substr($read,1,1);
       #switch ($status) {
       #     case 0 {print $log "$now Controller idle.\n"}
       #     case 1 {print $log "$now Controller waiting for first frame sync.\n"}
       #     case 2 {print $log "$now Controller currently rcving pocsag data (or locked).\n"}
       #     case 4 {print $log "$now Controller currently xmitting POCSAG.\n"}
       #     case 5 {print $log "$now Controller currently xmitting CW.\n"}
       #     else   {print $log "$now Unknown controller status: '$status'!\n";}
       #}

       switch ($ptt) {
            case 1 {
       #         print $log "$now TX is OFF.\n";
                $clear=1;
            }

            case 9 {
        #        print $log "$now TX is ON!\n";
                $clear=0;
            }
            else   {print $log "$now Unknown PTT status: '$ptt'!\n";}
       }


       return $clear;

}

sub PushToController {
                          my ($cmd)=@_;
                          my $responce;
                          my $flag;
                          my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now Requesting TX interval...";
                          my $accepted=RequestPTT(15);
                          while (!($accepted)) {
                              print $log "$now TX rejected by server or server failed, requesting again...";
                              sleep 1;
                              $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                              $accepted=RequestPTT(15);
                          }
                          print $log "$now TX accepted by server, sending to controller: '$cmd'\n";
                          $port->write("$cmd\r");
                          $flag=1;
                          my $read="";
                          while($flag) {
                            my $byte=$port->read(1);
                            my $ord=ord($byte);
                            if ($byte ne "\r") {$read="$read$byte";}
                            if ($ord eq 0) {$flag=0;}
                          }
                          $responce="Command was sent to controller, waiting for TX to complete...";
                          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now $responce\n";

                          my $clear=CheckControllerStatus();
                          while (!($clear)) {
                              sleep 1;
                              $clear=CheckControllerStatus();
                          }

                          if (index($cmd, $beacon) != -1) {
                              $responce="CW beacon sent";
                          } else {
                              $responce="Message sent";
                          }
                          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now $responce, withdrawing TX interval...";
                          WithdrawPTT();
                          $lasttx=time();
}

sub PushToControllerEmer {
                          my ($cmd)=@_;
                          my $responce;
                          my $flag;
                          my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now Sending to controller: '$cmd'\n";
                          $port->write("$cmd\r");
                          $flag=1;
                          my $read="";
                          while($flag) {
                            my $byte=$port->read(1);
                            my $ord=ord($byte);
                            if ($byte ne "\r") {$read="$read$byte";}
                            if ($ord eq 0) {$flag=0;}
                          }
                          $responce="Command was sent to controller, waiting for TX to complete...";
                          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now $responce\n";

                          my $clear=CheckControllerStatus();
                          while (!($clear)) {
                              sleep 1;
                              $clear=CheckControllerStatus();
                          }

                          if (index($cmd, $beacon) != -1) {
                              $responce="CW beacon sent";
                          } else {
                              $responce="Message sent";
                          }
                          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now $responce.\n";
                          $lasttx=time();

}

sub SendMessage {
                  my ($cap, $msg)=@_;
                  my $cmd;
                  chomp($msg);
                  $msg="$msg ";
                  my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                  $cap=substr($cap, rindex($cap, '/' ) + 1);
                  #my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                  #print $log "$now Received message '$msg' for CAP $cap...\n";
                  #print $log "$now Processing message '$msg' for CAP $cap...\n";
                  if ($cap eq "0000000") {
                      $cmd="m$beacon";
                      print $log "$now Sending CW beacon...\n";
                  } elsif ($cap eq "0000008") {
                      $cmd="#$msgtype,$baudrate,$invert,$cap,0,$pbeacon";
                      print $log "$now Sending POCSAG beacon...\n";
                  } else {
                      print $log "$now Received message '$msg' for CAP '$cap', processing...\n";
                      $cmd="#$msgtype,$baudrate,$invert,$cap,0,$msg";
                  }
                  if ($cmd) {PushToController($cmd);}
}

DetectDevice();
SubscribeMQTT();

my $now = strftime "%Y-%m-%d %H:%M:%S", localtime();

print $log "$now Ready to process messages.\n\n";


while ($continue) {
                      # waiting for a new client connection
                      #print $log "status=".$mqtt->status()."\n";
                      my @res;
                      eval {
                          @res = $mqtt->receivePub();
                      };
                      if ($@) {
                          $now = strftime "%Y-%m-%d %H:%M:%S", localtime();
                          print $log "$now Server connection error, reconnecting...\n";
                          SubscribeMQTT();
                      } else {
                          SendMessage($res[0], $res[1]);
                          #print $log Dumper( @res );
                      }
}
