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
sub tcp_server_child($$);
sub tcp_client();
sub tcp_active_open();
sub udp_server();
sub udp_client();
sub mywrite($$);
sub myread($);

sub socket_set_reuseaddr($);
sub socket_set_buffersize($$$);
sub socket_set_linger($$);
sub socket_set_debug($);
sub _format_log_params($;@);
sub _info(@);
sub _error(@);
sub _dumpvalue;


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
    "reuseaddr" => 1,
    "sleep-before-listen" => 5,
    "server" => 1,
    "service" => "echo",
    "tcp" => 1,
    "thread-num" => 1,
    "udp" => 0,
    "usleep-before-echo" => 0,
  );

Getopt::Long::Configure("bundling");
GetOptions(\%opts,
    "backlog=i",
    "bind",
    "client",
    "client-host=s",
    "client-port=i",
    "debug",
    "echo-by-package",
    "fork",
    "help|h",
    "linger=i",
    "logfile=s",
    "port=i",
    "reuseaddr!",
    "server",
    "service=s",
    "sleep-before-listen=i",
    "tcp",
    "thread-num=i",
    "udp",
    "usleep-before-echo=i",
  ) or die usage;

my $argv_num = scalar @ARGV;
usage if $opts{client} && $argv_num<2;

if ($argv_num == 1) {
  $opts{port} = $ARGV[0];
} elsif ($argv_num >= 2) {
  $opts{ip} = $ARGV[0];
  $opts{port} = $ARGV[1];
}

_dumpvalue \%opts;
usage if $opts{help};

sub usage() {
  print <<'_EOF_';

Usage:
    perl ksock.pl [options] port  <=> --server --tcp [options] port
    perl ksock.pl --tcp --server [options] [ip] [port]
    perl ksock.pl --tcp --client [options] ip [port]
    perl ksock.pl --udp --server [options] [ip] [port]
    perl ksock.pl --udp --client [options] ip [port]

General options:
    --help, -h
    --debug
    --fork        use process not thread to handle multi clients request
    --reuseaddr   when running as client, --bind should be setted
    --tcp, --udp

Server options:
    --echo-by-package
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


sub wait_children() {
  while (1) {
    my $pid = wait;
    last if $pid == -1;
    _info "$pid exit";
  }
}


if (defined $opts{fork}) {
  $SIG{CHLD} = \&wait_children;
}

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
  my $ip = $opts{ip};
  my $port = $opts{port};
  my $backlog = $opts{backlog};
  my $sleep_before_listen = $opts{"sleep-before-listen"};
  my $reuseaddr = $opts{reuseaddr};
  my $use_fork = $opts{fork};
  my $debug = $opts{debug};

  socket my $sockfd, AF_INET, SOCK_STREAM, 0 or die "open socket error, $!";
  socket_set_reuseaddr $sockfd if $reuseaddr;
  socket_set_debug $sockfd if defined $debug;

  my $addr;
  if (defined $ip) {
    $addr = sockaddr_in $port, inet_aton($ip);
  } else {
    $addr = sockaddr_in $port, INADDR_ANY;
  }

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
    if (defined $use_fork) {
      my $pid = fork;
      die "fork error, $!" if !defined $pid;
      if ($pid == 0) {
        close $sockfd;
        tcp_server_child $session, $remote_addr or die;
        exit;
      }

    } else {
      my $thread = threads->create("tcp_server_child", $session, $remote_addr);
      $thread->detach();
    }
  }
}


sub tcp_server_child($$) {
  my ($session, $remote_addr) = @_;
  my $service = $opts{service};
  my $echo_bypackage = $opts{"echo-by-package"};
  my $usleep_before_echo = $opts{"usleep-before-echo"};

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
      if (defined $echo_bypackage) {
        $buf =~ s/[\r\n]+$//;
        Time::HiRes::usleep $usleep_before_echo if $usleep_before_echo > 0;
        $n = syswrite $session, "REPLY with --> $buf\r\n";
        $buf = "";
        if (!defined $n) {
          _error "write fd error, $!";
          last;
        }

      } else {
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
  my $block = $opts{block};
  my $block_num = $opts{"block-num"};

  socket my $fd, AF_INET, SOCK_STREAM, 0 or die;

  if ($bind) {
    socket_set_reuseaddr $fd if $reuseaddr;
    my $client_port = $opts{"client-port"};
    my $client_host_str = $opts{"client-host"};
    my $client_host = INADDR_ANY;
    if (defined $client_host_str) {
      $client_host = inet_aton $client_host_str or die "inet_aton error, $!";
    }
    my $client_addr = sockaddr_in $client_port, $client_host;
    bind $fd, $client_addr or die "bind clientaddr error, $!";
  }

  # set send and recv buffer

  my $host = inet_aton $server_ip;
  my $dest_addr = sockaddr_in $server_port, $host;
  connect $fd, $dest_addr or die "connect error, $!";

  # 1) block data
  # 2) interactive data
  #    a) character by character
  #    b) line by line
  if (defined $block) {
    for my $i (1 .. $block_num) {
      mywrite $fd, "x" x 1024;
    }

  } else {
    mywrite $fd, "123";
    sleep 1;
    mywrite $fd, "456\r\n";

    mywrite $fd, "hello world\r\n";
    myread $fd or die;

#  shutdown $fd, KSHUT_RD;
    sleep 1;

    mywrite $fd, "again hello world\r\n" or die;
    myread $fd or die;
  }

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


sub socket_set_buffersize($$$) {
  my ($fd, $recvbuf_size, $sendbuf_size) = @_;

  setsockopt $fd, SOL_SOCKET, SO_RCVBUF, $recvbuf_size
      or die "set recv buffer size error, $!";
  setsockopt $fd, SOL_SOCKET, SO_SNDBUF, $sendbuf_size
      or die "set send buffer size error, $!";
}


sub socket_set_linger($$) {
  my ($fd, $timeout) = @_;

  setsockopt $fd, SOL_SOCKET, SO_LINGER, pack("II", 1, $timeout)
      or die "set linger error, $!";
}


sub socket_set_debug($) {
  my ($fd) = @_;

  setsockopt $fd, SOL_SOCKET, SO_DEBUG, 1
      or die "set socket debug error, $!";

  my $packed = getsockopt $fd, SOL_SOCKET, SO_DEBUG or die;
  die "open sodebug error, $!" if !unpack "I", $packed;
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


sub _dumpvalue {
  return if !defined $opts{debug};

  use Dumpvalue;
  Dumpvalue->new->dumpValues(@_);
}

