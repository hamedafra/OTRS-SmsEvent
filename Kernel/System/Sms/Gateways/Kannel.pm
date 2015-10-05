# --Copyright 2015 Hamed Afra
# --

package Kernel::System::Sms::Gateways::Kannel;

use strict;
use warnings;

use LWP;
use HTTP::Request;
use XML::Simple;
use Encode;

# disable redefine warnings in this scope
{
    no warnings 'redefine';

    # 
    # overwrite sub _TicketGetFirstResponse to get correct time and not only for escalated tickets
    sub Kernel::System::SmsEvent::SendSms {
        my ( $Self, %Param ) = @_;

        # get sms data
        my %Gateway = %{ $Param{Gateway} };
        my %Sms = %{ $Param{Sms} };
        my %Recipient = %{ $Param{Recipient} };

        # Clean MobileNumber
        my @S = ($Recipient{Email} =~ m/(\d+)/g);
        $Recipient{Email}=join("", @S);


        # Contruct the url
        my $url=$Gateway{URL}."?";
        $url.="user=$Gateway{user}&pass=$Gateway{password}";
        $url.="&to=$Recipient{Email}&text=$Sms{Body}&from=$Gateway{SenderID}&charset=utf-8&coding=2";
        
        # Send the sms
        my $ua = LWP::UserAgent->new();
        my $req;
	
        $req = new HTTP::Request GET => $url;
             
        my $res = $ua->request($req);
        
        if ($res->content =~ m/^ERR:/) {
		 $Kernel::OM->Get('Kernel::System::Log')->Log(
                 Priority => 'notice',
                 Message  => "Error on sending sms. Code: ".$res->content,
            );
            return 0;
        } else {
            return 1;
        }
    }
}

1;
