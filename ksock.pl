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
sub tcp_passive_open();
sub udp_server();
sub udp_client();
sub mywrite($$);
sub myread($);

sub _format_log_params;
sub _info;
sub _error;


my %opts = (
    "backlog" => 5,
    "client" => 0,
    "logfile" => "STDOUT",
    "port" => 9876,
    "sleep-before-listen" => 30,
    "server" => 1,
    "service" => "echo",
    "tcp" => 1,
    "thread-num" => 1,
    "udp" => 0,
  );

Getopt::Long::Configure("bundling");
GetOptions(\%opts,
    "backlog=i",
    "client",
    "help|h",
    "logfile=s",
    "port=i",
    "server",
    "service=s",
    "sleep-before-listen=i",
    "tcp",
    "thread-num",
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
    --tcp, --udp

Server options:
    --server
    --service=<service>   echo(default), discard
    --sleep-before-listen=<sleep-seconds> the default is 30

Client options:
    --client
    --thread-num  for tcp client, default is 1

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

  socket my $sockfd, AF_INET, SOCK_STREAM, 0 or die "open socket error, $!";
  setsockopt $sockfd, SOL_SOCKET, SO_REUSEADDR, 1 or die "set reuseaddr error, $!";
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
  while (1) {
    my $buf = "";
    my $n = sysread $session, $buf, 1024, length($buf);
    if (!defined $n) {
      _error "socket read error, $!";
      last;
    } elsif ($n == 0) {
      _info "peer close the socket";
      last;
    }

    my $log_buf = $buf;
    $log_buf =~ s/\r/\\r/;
    $log_buf =~ s/\n/\\n/;
    _info "receive --> ($n) $log_buf";

    if ($service eq "echo") {
      my $write_err = 0;
      if ($buf =~ /(.*)[^\r\n][\r\n]+(.*)$/) {
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
    tcp_passive_open;
    return ;
  }

  my @workers;
  for my $i (1 .. $thread_num) {
    my $thread = threads->create("tcp_passive_open");
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


sub tcp_passive_open() {
  my $server_ip = $opts{ip};
  my $server_port = $opts{port};

  socket my $fd, AF_INET, SOCK_STREAM, 0 or die;
  my $host = inet_aton $server_ip;
  my $dest_addr = sockaddr_in $server_port, $host;
  connect $fd, $dest_addr or die;

  mywrite $fd, "hello world\r\n";
  myread $fd or die;

  shutdown $fd, 0;
  sleep 1;

  mywrite $fd, "again hello world\r\n" or die;
  myread $fd or die;

  sleep 1;
  close $fd;
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


sub _format_log_params {
  my @params = @_;
  my @bufs = map { s/\r/\\r/g; s/\n/\\n/g; $_ } @params;
  my ($sec, $msec) = Time::HiRes::gettimeofday;
  my $time = sprintf "%s.%06d", POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($sec)), $msec;
  unshift @bufs, $time;
  join " ", @bufs;
}


sub _info {
  Log::Message::Simple::msg _format_log_params(@_), 1;
}


sub _error {
  Log::Message::Simple::error _format_log_params(@_), 1;
}
