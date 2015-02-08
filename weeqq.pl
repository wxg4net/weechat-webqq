#!/usr/bin/perl

use JSON;
use IO::Socket;
use IO::Socket::UNIX;
use Encode;
use Encode::Locale;
use Digest::MD5 qw(md5_hex);

our (%nick_group, %buffer_group, %friend_list, %client_group);
our ($client, $main_buf, $master);
$| = 1;

my $sock_path = '/tmp/webqq.sock';
unlink $sock_path if -e $sock_path;

my %commands = (
  'clean'          => \&_msg_func_clean,
  'STDOUT'         => \&_msg_func_stdout,
  'STDERR'         => \&_msg_func_stderr,
  'user'           => \&_msg_func_user,
  'friend'         => \&_msg_func_friend,
  'recent'         => \&_msg_func_recent,
  'group'          => \&_msg_func_group,
  'member'         => \&_msg_func_member,
  'message'        => \&_msg_func_message,
  'group_message'  => \&_msg_func_group_message,
  'sess_message'   => \&_msg_func_sess_message,
  'info'           => \&_msg_func_info,
);


sub _send_json 
{
  my $type = shift;
  my $data = shift;
  $type = { type => $type, data => $data } if ref($type) ne  'HASH';
  my $output = JSON->new->utf8->encode($type);
  my $len    = pack "N", length($output);
  $client->send($len);
  $client->send($output);
}

sub _format_timestamp {
  my $timestamp = shift;
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($timestamp);
  return sprintf "%02d:%02d:%02d", $hour, $min, $sec;
}

sub _msg_func_clean {
  weechat::print($main_buf, "*\t清理webqq环境...");
  %friend_list = ();
  %nick_group  = ();
  while (my ($key,$val) = each %buffer_group) {
    if ($buffer_group{$key} ne $main_buf) {
      weechat::buffer_close($buffer_group{$key});
      delete $buffer_group{$key};
    }
    else {
      my $has_nicklist = weechat::buffer_get_integer($main_buf, "nicklist");
      if ($has_nicklist == 0) {
        weechat::buffer_set($main_buf, "nicklist", "1");
      }
      # weechat::nicklist_remove_all($main_buf);
    }
  }
}

sub _msg_func_stdout {
  my $data = shift;
  my $output =  sprintf("*\t%s", decode("utf-8", $data)); 
  weechat::print($main_buf, $output);
}

sub _msg_func_stderr {
  my $data = shift;
  my $color = weechat::color('red');
  my $output =  sprintf("*\t%s%s", $color, decode("utf-8", $data)); 
  weechat::print($main_buf, $output);;
}

sub _msg_func_user {
  my $master = shift;
  my $nick = '(i)';
  if ($master->{nick}) {
    $nick = decode("utf-8", $master->{nick}).$nick;
  }
  weechat::buffer_set($main_buf, "localvar_set_nick", $nick);
}

sub _msg_func_friend {
  my $friend = shift;
  my $categorie = decode("utf-8", $friend->{categorie});
  unless ($nick_group{$categorie}) {
    $nick_group{$categorie} = 
      weechat::nicklist_add_group($main_buf, "", $categorie, "", 1);
  }
  my $nick =  $friend->{uin}."(".decode("utf-8", $friend->{nick}).")";
     $nick =~  s/^\s+|\s+$//g;
  push( @{ $friend_list { $nick } }, $friend->{markname} ); 
  my $prefix = ' ';
  my $online_color = 'bar_fg';
  $prefix = '+' if $friend->{state};
  $online_color = 'lightgreen' if $friend->{state} and $friend->{state} eq  'online';
  weechat::nicklist_add_nick($main_buf, 
    $nick_group{$categorie}, $nick, $online_color, $prefix, '', 1);
}

sub _msg_func_recent {
  my $friend = shift;
  my $nick =  $friend->{uin}."(".decode("utf-8", $friend->{nick}).")";
     $nick =~  s/^\s+|\s+$//g;
  weechat::print($main_buf, "*\tnotice: ".$nick);
}

sub _msg_func_group {
  my $group = shift;
  return undef if $buffer_group{$group->{gid}};
  my $buf_name = decode("utf-8", $group->{name});
  my $has_buf = weechat::buffer_search('perl', $buf_name);
  if ($has_buf) {
    $buffer_group{$group->{gid}} = $has_buf;
  }
  else {
    $buffer_group{$group->{gid}} = 
      weechat::buffer_new($buf_name , "buffer_group_input_cb", $group->{gid}, "buffer_group_close_cb", $group->{gid});
    weechat::buffer_set($buffer_group{$group->{gid}}, "localvar_set_nick", '(i)');
  }
  weechat::buffer_set($buffer_group{$group->{gid}}, "nicklist", "1");
}

sub _msg_func_member {
  my $msg  = shift;
  my $gid  = $msg->{gid};
  my $user = $msg->{data};
  my $nick = decode("utf-8", $user->{nick});
     $nick =~  s/^\s+|\s+$//g;
     $nick = $user->{uin}."(".substr($nick,0,4).")";
  weechat::nicklist_add_nick($buffer_group{$gid}, '', $nick, 'bar_fg', '', '', 1);
}

sub _msg_func_message {
  my $msg   = shift;
  my $extra = shift;
  my $nick = decode("utf-8", $msg->{from_nick});
     $nick = '未知' unless $nick;
  unless ($buffer_group{$msg->{from_uin}}) {
    $extra = '' unless $extra;
    $buffer_group{$msg->{from_uin}} = 
      weechat::buffer_new($nick, "buffer_friend_input_cb", $msg->{from_uin}.'###'.$extra, "buffer_friend_close_cb", $msg->{from_uin});
    weechat::buffer_set($buffer_group{$msg->{from_uin}}, "localvar_set_nick", '(i)');
  }
  weechat::print_date_tags($buffer_group{$msg->{from_uin}}, $msg->{msg_time}, '', $nick."\t".decode("utf-8", $msg->{content}));
}

sub _msg_func_group_message {
  my $msg = shift;
  my $nick  = decode("utf-8", 
    $msg->{from_card}
      ? $msg->{from_card}
      : $msg->{from_nick}
  );
  my $content = substr($msg->{send_uin},0,4).'('.$nick.")\t".decode("utf-8", $msg->{content});
  my $gid     = $msg->{from_uin};
  if ($buffer_group{$gid}) {
    weechat::print_date_tags($buffer_group{$gid}, $msg->{msg_time}, '', $content);
  }
  else {
    _msg_func_stderr("$gid in \$buffer_group not found");
    weechat::print($main_buf, $content);
  }
}

sub _msg_func_sess_message {
  my $msg = shift;
  my $extra = $msg->{group_code};
  _msg_func_message($msg, $extra);
}

sub _msg_func_info {
  my $msg = shift;
  my $color = weechat::color("lightgreen");
  my $output =  sprintf("%s-->\t%s%s", $color, $color, decode("utf-8", $msg->{content}));
  weechat::print($buffer_group{$msg->{gid}}, "$output");
}

sub buffer_input_cb
{
  my $data    = shift;
  my $buffer  = shift;
  my $message = shift;
  if ($message =~ /(\d+)\((.*)\): *(.+)/g){
    my %data = ('to_uin'=>$1, 'content'=>$3);
    _send_json('message', \%data);
    weechat::print($buffer, "-->\t发送至$2：$3");
  }
  else {
    weechat::print($buffer, "-->\t消息格式错误");
  }
  return weechat::WEECHAT_RC_OK;
}

# 卸载
sub buffer_close_cb
{
  if (%buffer_group) {
    while (my ($key,$val) = each %buffer_group) {
      weechat::buffer_close($buffer_group{$key});
    }
  }
  weechat::unhook_all();
  return weechat::WEECHAT_RC_OK;
}

# 好友对话
sub buffer_friend_input_cb
{
  my $parm    = shift;
  my $buffer  = shift;
  my $content = shift;
  my $color = weechat::color("lightgreen");
  my $type  = 'message';
  my @parms = split '###', $parm;
  my %data  = (
    'to_uin'  => $parms[0], 
    'content' => $content,
  );
  if ($parms[1]) {
    $data{'group_code'} = $parms[1];
    $type = 'sess_message';
  }
  _send_json($type, \%data);
  weechat::print($buffer, $color."<--\t".$color.$content);
  return weechat::WEECHAT_RC_OK;
}

# 好友对话关闭
sub buffer_friend_close_cb
{
  my $uid = shift;
  delete $buffer_group{$uid};
  return weechat::WEECHAT_RC_OK;
}

# 群对话
sub buffer_group_input_cb
{
  my $to_uin  = shift;
  my $buffer  = shift;
  my $content = shift;
  $content =~ s/^\d+\((.*?)\):/\@$1/;
  my %data = (
    'to_uin'  => $to_uin, 
    'content' => $content
  );
  _send_json('group_message', \%data);
  my $color = weechat::color("lightgreen");
  weechat::print($buffer, $color."<--\t".$color.$content);
  return weechat::WEECHAT_RC_OK;
}

# 群对话关闭
sub buffer_group_close_cb
{
  my $name = shift;
  delete $buffer_group{$name};
  return weechat::WEECHAT_RC_OK;
}

# 搜索好友
sub webqq_cmd_qsearch{
  my ($data, $buffer, $args) = @_;
  my $index = 0;
  my $allow_open_buffer = 0;
  $keyword = decode("utf-8", $args);
  if (substr($keyword,0,1) eq ':') {
    $keyword = substr($keyword,1);
    $allow_open_buffer = 1;
  }
  weechat::print($buffer, "-->\t搜索关键词: ".$args);
  while (my ($nick,$markname)=each %friend_list){
    if ($markname =~ /$keyword/ || $nick =~ /$keyword/ ) {
      $index++;
      weechat::print($buffer, "-->\t".$nick);
      if ($allow_open_buffer) {
        $nick =~ m/(\d+)\((.*)\)/ig;
        my $msg = {
          'from_uin'  => $1,
          'from_nick' => encode('utf-8', $2),
          'msg_time'  => time,
          'content'   => '对话窗口已为你准备好',
        };
        _msg_func_message($msg);
      }
    }
  }
  if ($index) {
    weechat::print($buffer, "-->\t已搜索完成。找到 ($index) 符合条件的人");
  }
  else {
    my $err_color =  weechat::color('red');
    weechat::print($buffer, $err_color."-->\t".$err_color."抱歉未找到相关的人");
  }
  return weechat::WEECHAT_RC_OK;
}

# 获取加密后的密码
sub webqq_cmd_qpass {
  my ($data, $buffer, $passwd) = @_;
  $passwd = md5_hex($passwd);
  weechat::print($buffer, "-->\t安全密码：".$passwd);
  return weechat::WEECHAT_RC_OK;
}

# 更改在线状态
sub webqq_cmd_qstatus {
  my ($data, $buffer, $status) = @_;
  _send_json('change_status', $status);
  weechat::print($buffer, "<--\t状态( $status )修改指令已发出");
  return weechat::WEECHAT_RC_OK;
}

# 更改群信息
sub webqq_cmd_qgroup {
  my ($data, $buffer, $status) = @_;
  _send_json('update_group', '');
  weechat::print($buffer, "<--\t群更新指令已发出");
  return weechat::WEECHAT_RC_OK;
}

# 重新登录
sub webqq_cmd_relogin {
  my ($data, $buffer, $status) = @_;
  _send_json('relogin', '');
  weechat::print($buffer, "<--\t重新登录指令已发出");
  return weechat::WEECHAT_RC_OK;
}

# 查看用户详细信息
sub webqq_cmd_query {
  my ($data, $buffer, $user) = @_;
  my $gid;
  for my $key (sort keys %buffer_group){
    if ($buffer_group{$key} eq $buffer) {
      $gid = $key;
      last;
    }
  }
  if ($user =~ /(\d+)\((.*)\)/g){
    my $uin = $1;
    my %data = (uin=>$uin, gid=>$gid);
    _send_json('info', \%data);
    weechat::print($buffer, "<--\t查询 [$uin] 指令从 [$gid] 发出");
  }
  return weechat::WEECHAT_RC_OK_EAT ;
}

sub webqq_fd_cb {
  my $p  = shift;
  my $fd = shift;
  $client->recv(my $len, 4);
  if (length($len) == 0) {
    buffer_close_cb();
    return weechat::WEECHAT_RC_OK;
  }
  $len = unpack "N", $len;
  $client->recv(my $json, $len);
  
  my $command = JSON->new->utf8->decode($json);
  eval {
    &{$commands{$command->{type}}}($command->{data});
  };
  weechat::print($main_buf, "-->\t{$command->{type}} ~~ $@") if $@;
  return weechat::WEECHAT_RC_OK;
};

weechat::register('webqq', "wxg4dev", '0.1',  "GPL3",  "QQ message with list of buffers", "", "");
weechat::hook_command("qsearch", "Seach uin by markname or nick",
                     "<keyword>",
                     "buddy: buddy id",
                     "",
                     "webqq_cmd_qsearch", "");
weechat::hook_command("qpass", "safe you password",
                     "<keyword>",
                     "password: you qq password",
                     "",
                     "webqq_cmd_qpass", "");
weechat::hook_command("qgroup", "update qq group info",
                     "<keyword>",
                     "update qq group info",
                     "",
                     "webqq_cmd_qgroup", "");
weechat::hook_command("qrelogin", "relogin qq",
                     "<keyword>",
                     "relogin",
                     "",
                     "webqq_cmd_relogin", "");
weechat::hook_command("qstatus", "change online status",
                     "<keyword>",
                     "status: online|away|busy|silent|hidden|offline",
                     "online|away|busy|silent|hidden|offline",
                     "webqq_cmd_qstatus", "");
weechat::hook_command_run("/query *", "webqq_cmd_query", "");

$main_buf = weechat::buffer_new("QQ", "buffer_input_cb", "", "", "");
$buffer_group{main_buf} = $main_buf;
weechat::buffer_set($main_buf, "title", "QQ buffer");
weechat::buffer_set($main_buf, "localvar_set_no_log", "0");
weechat::buffer_set($main_buf, "localvar_set_nick", '(i)');

my $server_path = weechat::config_get_plugin("server_path");
my $qq          = weechat::config_get_plugin("qq");
my $pwd         = weechat::config_get_plugin("pwd");

if ($server_path 
  && $qq 
  && $pwd) {
  my $socket = IO::Socket::UNIX->new(
      Local  => $sock_path,
      Type   => SOCK_STREAM,
      Listen => 1,
  );
  weechat::hook_process("perl $server_path $sock_path", 0, "buffer_close_cb", '');
  $client = $socket->accept;
  my %info = (qq=>$qq, pwd=>$pwd);
  _send_json('login', \%info);
  my $fileno = $client->fileno();
  weechat::hook_fd($fileno, 1, 0, 0, "webqq_fd_cb", "");
}
else {
  weechat::print($main_buf, "*\t请设置必要的参数");
  weechat::print($main_buf, "*\t一)webqq服务路径 /set plugins.var.perl.webqq.server_path file_path");
  weechat::print($main_buf, "*\t二)设置qq账户 /set plugins.var.perl.webqq.qq 12345678");
  weechat::print($main_buf, "*\t三)获取qq密码 /qpass 87654321");
  weechat::print($main_buf, "*\t三)设置qq密码 /set plugins.var.perl.webqq.pwd md5_hex");
  weechat::print($main_buf, "*\t四)运行 /save 保存。然后重载插件即可");
}
