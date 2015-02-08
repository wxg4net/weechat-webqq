use strict;
use warnings;

use Cwd qw/abs_path/;
use File::Basename;
use lib abs_path(dirname(__FILE__)).'/Webqq-Client/lib/';

use JSON;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Webqq::Client;
use Digest::MD5 qw(md5_hex);
use Webqq::Client::Util qw(console code2client);

our ($client, $handle);
$| = 1;

my %commands = (
  'login'         => \&_msg_func_login,
  'message'       => \&_msg_func_message,
  'group_message' => \&_msg_func_group_message,
  'sess_message'  => \&_msg_func_sess_message,
  'relogin'       => \&_msg_func_relogin,
  'info'          => \&_msg_func_info,
  'update_group'  => \&_msg_func_update_group,
  'change_status' => \&_msg_func_change_status,
);

# 数据被包装成json格式发送
sub _send_json {
  my $type = shift;
  my $data = shift;
  # my ($hdl, $type, $data) = @_;
  $type = { type => $type, data => $data } if ref($type) ne  'HASH';
  my $output = JSON->new->utf8->encode($type);
  my $len    = pack "N", length($output);
  $handle->push_write($len);
  $handle->push_write($output);
}

sub _send_qq_database {
  my $code = shift;
  $code = 127 unless $code;
  if ($code == 127) {
    _send_json('clean', 'init');
  }
  _send_json('STDOUT', '准备发送用户数据...');
  # 发送已获取的 qq_database 数据
  foreach my $key ( keys %{ $client->{qq_database} } ) {
    if ($key eq 'user' && ($code & 1)) {
      _send_json('user', $client->{qq_database}{user});
    }
    elsif ($key eq 'friends' && ($code & 2)) {
      for my $f ( @{ $client->{qq_database}{friends} }){;
        _send_json('friend', $f);
      }
    }
    elsif ($key eq 'group' && ($code & 4)) {
      for my $g ( @{$client->{qq_database}{group}} ){
        _send_json('group', $g->{ginfo});
        for my $m (@{ $g->{minfo}  }){
          my %data = (
            gid   => $g->{ginfo}{gid}, 
            gname => $g->{ginfo}{name},
            data  => $m,
          );
          _send_json('member', \%data);
        }
      } 
    }
    elsif ($key eq 'recent_list' && ($code & 8)) {
      for my $f ( @{ $client->{qq_database}{recent_list} }){
        if ($f->{type} == 0) {
          my $recent = $client->search_friend($f->{uin});
          if ($recent ) {
            _send_json('recent', $recent);
          }
        }
      }
    }
    else { }
  }
  _send_json('STDOUT', '用户数据已发送完成');
}

# 登录
sub _msg_func_login {
  my $user = shift;
  $client = Webqq::Client->new(debug=>0, timeout=>60);
  $client->load("ImgVerifycodeFromSocket");
  $client->on_input_img_verifycode() = sub{
    my ($img_verifycode_file) = @_;
    _send_json('STDOUT', 
      "主银，请点击此链接( http://127.0.0.1:1987/post_img_code )输入验证码.");
    return &{$client->plugin("ImgVerifycodeFromSocket")}($client,$img_verifycode_file);
  };

  $client->on_login() = sub{
    _send_qq_database();
  };

  $client->on_send_message = sub{
    my ($msg,$is_success,$status) = @_;
    my %data;
    unless ($is_success) {
      _send_json('STDERR', '发送失败('.$msg->{content}.')');
    }   
  };
  
  $client->on_receive_offpic = sub{
      my($fh,$filename) = @_;
      _send_json('STDOUT', "file://".$filename);
  };
  
  $client->on_receive_message = sub{
    my $msg = shift;
    $client->call("StopSpam", $msg);
    $client->call("SmartReplyForProject", $msg);
    my %data = (
      'msg_type'    => $msg->{type}, 
      'msg_time'    => $msg->{msg_time}, 
      'content'     => $msg->{content}, 
      'from_nick'   => $msg->from_nick(), 
      'from_uin'    => $msg->{from_uin}, 
      'send_uin'    => $msg->{send_uin}, 
    );
    if ($msg->{type} eq 'group_message') {
      $data{'group_name'} = $msg->group_name();
      $data{'from_card'}  = $msg->from_card();
    }
    elsif($msg->{type} eq 'sess_message') {
      $data{'group_code'}   = $msg->{group_code};
    }
    _send_json($msg->{type}, \%data);
  };
  
  $client->login( qq=> $user->{qq}, pwd => $user->{pwd});
  $client->run;
}

# 发送好友消息
sub _msg_func_message {
  my $data = shift;
  my $msg = $client->create_msg(
    to_uin  => $data->{to_uin}, 
    content => $data->{content}
  );
  $client->send_message($msg);
}

# 发送群消息
sub _msg_func_group_message {
  my $data = shift;
  my $msg = $client->create_group_msg(
    to_uin  => $data->{to_uin}, 
    content => $data->{content}
  );
  $client->send_group_message($msg);
}

# 发送群临时消息
sub _msg_func_sess_message {
  my $data = shift;
  my $msg = $client->create_sess_msg(
    to_uin  => $data->{to_uin}, 
    content => $data->{content},
    group_code  => $data->{group_code},
  );
  $client->send_sess_message($msg);
}

# 重新登录
sub _msg_func_relogin {
  my $msg = shift;
  $client->relogin();
}

# 修改在线状态
sub _msg_func_change_status {
  my $status = shift;
  $client->change_status($status);
}

# 更新好友或群成员列表
sub _msg_func_update_group {
  my $msg = shift;
  $client->update_group_info();
  _send_qq_database(4);
}

# 更新好友或群成员列表
sub _msg_func_info {
  my $data = shift;
  my $content = '查询结果';
  if ($data->{gid} ne 'main_buf') {
    my $gcode  = $client->get_group_code_from_gid($data->{gid});
    my $member = $client->search_member_in_group($gcode, $data->{uin});
    if ($member) {
      $content .= "\n昵称：".$member->{nick} .
                  "\n性别：".$member->{gender} .
                  "\n号码：".$client->get_qq_from_uin($data->{uin}) .
                  "\n省份：".$member->{province} .
                  "\n城市：".$member->{city};
    }
  }
  else {
    my $member = $client->search_friend($data->{uin});
    if ($member) {
      $content .= "\n昵称：".$member->{nick} .
                  "\n状态：".$member->{state}.
                  "\n程序：".code2client($member->{client_type}).
                  "\nQQ号：".$client->get_qq_from_uin($data->{uin});
    }
  }
  my %msg = (
    gid     => $data->{gid},
    content => $content
  );
  _send_json('info', \%msg);
}

# 分析接受到的指令
sub _parse_receive_msg {
  my $command = shift;
  eval {
    &{$commands{$command->{type}}}($command->{data});
  };
  if ($@) {
    print $@;
    _send_json('STDERR', $@);
  }
};

# 主动连接成功后执行
sub _callback_connect  {
  my ($fh, ) = @_;
  $handle = new AnyEvent::Handle
    fh       => $fh,
    on_error => sub {
      AE::log error => $_[2];
      $_[0]->destroy;
      $handle->destroy;
    },
    on_eof   => sub {
      $handle->destroy; 
      AE::log info => "Done.";
    };
  $handle->on_read(sub {
    shift->unshift_read(chunk => 4, sub {
      my $len = unpack "N", $_[1];
      shift->unshift_read(chunk => $len, sub {
        my $json = $_[1];
        my $command = JSON->new->utf8->decode($json);
        _parse_receive_msg($command);
      });
    });
  });
};

# 运行 
sub run {
  # my $sock_path = '/tmp/webqq.sock';
  my $sock_path = $ARGV[0];
  die "Unknown WebQQ socket's path!" unless -e $sock_path;
  tcp_connect "unix/", $sock_path, \&_callback_connect;
  my $cv = AE::cv;
  $cv->recv;
}
  
run();