#! /usr/bin/env perl
# Copyleft (C) KRT, 2014 by kiterunner_t

use strict;
use warnings;

use 5.10.0;
use Getopt::Long;
use Log::Message::Simple;
use POSIX;
use Socket;
use threads;
use Time::HiRes;


sub usage();
sub tcp_server();
sub tcp_client();
sub tcp_active_open();
sub udp_server();
sub udp_client();
sub mywrite($$);
sub myread($);

sub socket_set_reuseaddr($);
sub socket_set_linger($$);
sub _format_log_params($;@);
sub _info(@);
sub _error(@);


use constant {
    KSHUT_RD => 0,
    KSHUT_WD => 1,
    KSHUT_RDWD => 2,
  };


my %opts = (
    "backlog" => 5,
    "bind" => 0,
    "client" => 0,
    "logfile" => "STDOUT",
    "port" => 9876,
    "reuseaddr" => 0,
    "sleep-before-listen" => 5,
    "server" => 1,
    "service" => "echo",
    "tcp" => 1,
    "thread-num" => 1,
    "udp" => 0,
  );

Getopt::Long::Configure("bundling");
GetOptions(\%opts,
    "backlog=i",
    "bind",
    "client",
    "client-host=s",
    "client-port=i",
    "help|h",
    "linger=i",
    "logfile=s",
    "port=i",
    "reuseaddr",
    "server",
    "service=s",
    "sleep-before-listen=i",
    "tcp",
    "thread-num=i",
    "udp",
  ) or die usage;

$opts{ip} = $ARGV[0];

usage if $opts{help};

sub usage() {
  print <<'_EOF_';

Usage:
    perl ksock.pl [options] port  <=> --server --tcp [options] port
    perl ksock.pl --tcp --server [options] [port]
    perl ksock.pl --tcp --client [options] ip [port]
    perl ksock.pl --udp --server [options] [port]
    perl ksock.pl --udp --client [options] ip [port]

General options:
    --help, -h
    --reuseaddr   when running as client, --bind should be setted
    --tcp, --udp

Server options:
    --server
    --service=<service>   echo(default), discard
    --sleep-before-listen=<sleep-seconds> the default is 30

Client options:
    --bind
    --client
    --client-host=<ip>
    --client-port=<port>
    --linger=<time>
    --thread-num=<num>  for tcp client, default is 1

Examples:
    perl ksock.pl --tcp --server 9876
    perl ksock.pl --tcp --client 192.168.47.120 9876

_EOF_

  exit(0);
}


# tcp
# 1) interactive data flow
# 2) bulk data flow, sliding window, slow start
# 3) URG

my $logfd;
if ($opts{logfile} ne "STDOUT") {
  open $logfd, ">>", $opts{logfile} or die;
} else {
  $logfd = *STDOUT;
}
local $Log::Message::Simple::MSG_FH = $logfd;
local $Log::Message::Simple::ERROR_FH = $logfd;

if ($opts{tcp}) {
  if ($opts{client}) {
    tcp_client;
  } elsif ($opts{server}) {
    tcp_server;
  }

} else {
  if ($opts{client}) {
    udp_client;
  } elsif ($opts{server}) {
    udp_server;
  }
}


sub tcp_server() {
  my $port = $opts{port};
  my $backlog = $opts{backlog};
  my $sleep_before_listen = $opts{"sleep-before-listen"};
  my $reuseaddr = $opts{reuseaddr};

  socket my $sockfd, AF_INET, SOCK_STREAM, 0 or die "open socket error, $!";
  if ($reuseaddr) {
    socket_set_reuseaddr $reuseaddr;
  }

  my $addr = sockaddr_in $port, INADDR_ANY;
  bind $sockfd, $addr or die "bind $sockfd in $port error, $!";
  listen $sockfd, $backlog or die "listen $sockfd error, $!";

  # there is only one instance, so I can do this
  $| = 1;
  for my $i (1 .. $sleep_before_listen) {
    sleep 1;
    print $logfd ".";
  }
  print $logfd "\n";

  while (1) {
    my $session;
    next unless my $remote_addr = accept $session, $sockfd;
    my $thread = threads->create("tcp_server_child", $session, $remote_addr);
    $thread->detach();
  }
}


sub tcp_server_child() {
  my ($session, $remote_addr) = @_;
  my $service = $opts{service};

  my ($peer_port, $peer_netaddr) = sockaddr_in $remote_addr;
  my $peer_addr = inet_ntoa $peer_netaddr;

  _info "accept $peer_addr:$peer_port";
  my $buf = "";
  while (1) {
    my $n = sysread $session, $buf, 1024, length($buf);
    if (!defined $n) {
      _error "socket read error, $!";
      last;
    } elsif ($n == 0) {
      _info "peer close the socket";
      last;
    }

    my $diff = length($buf) - $n;
    _info "receive --> ($n/$diff) $buf";

    if ($service eq "echo") {
      my $write_err = 0;
      if ($buf =~ /(.*[^\r\n])[\r\n]+([^\r\n]*)$/ms) {
        $buf = "";
        $buf = $2 if defined $2;
        $n = syswrite $session, "REPLY with --> " . $1 . "\r\n";
        if (!defined $n) {
          _error "write fd error, $!";
          last;
        }

      } else {
        next;
      }

    } elsif ($service eq "discard") {
      # do nothing, just discard ...

    } else {
      last;
    }
  }

  close $session;
}


sub tcp_client() {
  my $thread_num = $opts{"thread-num"};

  if ($thread_num == 1) {
    tcp_active_open;
    return ;
  }

  my @workers;
  for my $i (1 .. $thread_num) {
    my $thread = threads->create("tcp_active_open");
    # $thread->detach();
    push @workers, $thread;
  }

  for my $thread (sort { $a->tid() <=> $a->tid() } @workers) {
    # print $thread->tid . "\n";
    $thread->join();
  }
}


sub udp_server() {
}


sub udp_client() {
}



sub tcp_active_open() {
  my $server_ip = $opts{ip};
  my $server_port = $opts{port};
  my $bind = $opts{bind};
  my $reuseaddr = $opts{reuseaddr};
  my $linger_time = $opts{linger};

  socket my $fd, AF_INET, SOCK_STREAM, 0 or die;

  if ($reuseaddr) {
    socket_set_reuseaddr($fd);
  }

  if ($bind) {
    my $client_port = $opts{"client-port"};
    my $client_host_str = $opts{"client-host"};
    my $client_host = INADDR_ANY;
    if (defined $client_host_str) {
      $client_host = inet_aton $client_host_str or die "inet_aton error, $!";
    }
    my $client_addr = sockaddr_in $client_port, $client_host;
    bind $fd, $client_addr or die "bind clientaddr error, $!";
  }

  my $host = inet_aton $server_ip;
  my $dest_addr = sockaddr_in $server_port, $host;
  connect $fd, $dest_addr or die "connect error, $!";

  mywrite $fd, "123";
  sleep 1;
  mywrite $fd, "456\r\n";

  mywrite $fd, "hello world\r\n";
  myread $fd or die;

#  shutdown $fd, KSHUT_RD;
  sleep 1;

  mywrite $fd, "again hello world\r\n" or die;
  myread $fd or die;

  if (defined $linger_time) {
    socket_set_linger $fd, $linger_time;

  } else {
    sleep 1;
    close $fd;
  }
}


sub myread($) {
  my ($fd) = @_;

  my $n = sysread $fd, my $buf, 1024;
  if (!defined $n) {
    _error "sysread error, $!";
    return 0;

  } elsif ($n == 0) {
    _info "peer close the socket";
    return 0;

  } else {
    _info $buf;
    return $n;
  }
}


sub mywrite($$) {
  my ($fd, $buf) = @_;

  my $n = syswrite $fd, $buf;
  if (!defined $n) {
    _error "write socket error, $!";
    return 0;
  }

  1;
}


sub socket_set_reuseaddr($) {
  my ($fd) = @_;

  setsockopt $fd, SOL_SOCKET, SO_REUSEADDR, 1
      or die "reuseaddr error, $!";
}


sub socket_set_linger($$) {
  my ($fd, $timeout) = @_;

  setsockopt $fd, SOL_SOCKET, SO_LINGER, pack("II", 1, $timeout)
      or die "set linger error, $!";
}


sub _format_log_params($;@) {
  my $with_service = shift;
  my @params = @_;
  my @bufs = map { s/\r/\\r/g; s/\n/\\n/g; $_ } @params;
  my ($sec, $msec) = Time::HiRes::gettimeofday;
  my $time = sprintf "%s.%06d",
      POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($sec)), $msec;

  if ($with_service) {
    unshift @bufs, "[$opts{service}]";
  }

  unshift @bufs, $time;
  join " ", @bufs;
}


sub _info(@) {
  Log::Message::Simple::msg _format_log_params(1, @_), 1;
}


sub _error(@) {
  Log::Message::Simple::error _format_log_params(1, @_), 1;
}

