# --
# Kernel/System/SmsEvent.pm - notification system module
# Copyright (C) 2001-2015 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --
# SMSevent By Hamed Afra

package Kernel::System::SmsEvent;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::System::DB',
    'Kernel::System::Log',
    'Kernel::System::Valid',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    return $Self;
}

=item NotificationList()

returns a hash of all notifications

    my %List = $NotificationEventObject->NotificationList();

=cut

sub SmsList {
    my ( $Self, %Param ) = @_;

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    $DBObject->Prepare( SQL => 'SELECT id, name FROM sms_event' );

    my %Data;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $Data{ $Row[0] } = $Row[1];
    }

    return %Data;
}

=item NotificationGet()

returns a hash of the notification data

    my %Notification = $NotificationEventObject->NotificationGet( Name => 'NotificationName' );

    my %Notification = $NotificationEventObject->NotificationGet( ID => 123 );

=cut

sub SmsGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{Name} && !$Param{ID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need Name or ID!'
        );
        return;
    }

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    if ( $Param{Name} ) {
        $DBObject->Prepare(
            SQL => 'SELECT id, name, subject, text, content_type, charset, valid_id, '
                . 'comments, create_time, create_by, change_time, change_by '
                . 'FROM sms_event WHERE name = ?',
            Bind => [ \$Param{Name} ],
        );
    }
    else {
        $DBObject->Prepare(
            SQL => 'SELECT id, name, subject, text, content_type, charset, valid_id, '
                . 'comments, create_time, create_by, change_time, change_by '
                . 'FROM sms_event WHERE id = ?',
            Bind => [ \$Param{ID} ],
        );
    }

    my %Data;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $Data{ID}         = $Row[0];
        $Data{Name}       = $Row[1];
        $Data{Subject}    = $Row[2];
        $Data{Body}       = $Row[3];
        $Data{Type}       = $Row[4];
        $Data{Charset}    = $Row[5];
        $Data{ValidID}    = $Row[6];
        $Data{Comment}    = $Row[7];
        $Data{CreateTime} = $Row[8];
        $Data{CreateBy}   = $Row[9];
        $Data{ChangeTime} = $Row[10];
        $Data{ChangeBy}   = $Row[11];
    }

    return if !%Data;

    $DBObject->Prepare(
        SQL => 'SELECT event_key, event_value FROM sms_event_item ' .
            ' WHERE sms_id = ?',
        Bind => [ \$Data{ID} ],
    );

    while ( my @Row = $DBObject->FetchrowArray() ) {
        push @{ $Data{Data}->{ $Row[0] } }, $Row[1];
    }

    return %Data;
}

=item SmsAdd()

adds a new notification to the database

    my $ID = $NotificationEventObject->SmsAdd(
        Name    => 'JobName',
        Subject => 'JobName',
        Body    => 'JobName',
        Type    => 'text/plain',
        Charset => 'iso-8895-1',
        Data => {
            Events => [ 'TicketQueueUpdate', ],
            ...
            Queue => [ 'SomeQueue', ],
        },
        Comment => 'An optional comment', # Optional
        ValidID => 1,
        UserID  => 123,
    );

=cut

sub SmsAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(Name Subject Body Type Charset Data UserID)) {
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # check if job name already exists
    my %Check = $Self->SmsGet( Name => $Param{Name} );
    if (%Check) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Can't add notification '$Param{Name}', notification already exists!",
        );
        return;
    }

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # fix some bad stuff from some browsers (Opera)!
    $Param{Body} =~ s/(\n\r|\r\r\n|\r\n|\r)/\n/g;

    # insert data into db
    return if !$DBObject->Do(
        SQL => 'INSERT INTO sms_event '
            . '(name, subject, text, content_type, charset, valid_id, comments, '
            . 'create_time, create_by, change_time, change_by) VALUES '
            . '(?, ?, ?, ?, ?, ?, ?, current_timestamp, ?, current_timestamp, ?)',
        Bind => [
            \$Param{Name},    \$Param{Subject}, \$Param{Body},
            \$Param{Type},    \$Param{Charset}, \$Param{ValidID},
            \$Param{Comment}, \$Param{UserID},  \$Param{UserID},
        ],
    );

    # get id
    $DBObject->Prepare(
        SQL  => 'SELECT id FROM sms_event WHERE name = ?',
        Bind => [ \$Param{Name} ],
    );

    my $ID;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ID = $Row[0];
    }

    return if !$ID;

    for my $Key ( sort keys %{ $Param{Data} } ) {

        ITEM:
        for my $Item ( @{ $Param{Data}->{$Key} } ) {

            next ITEM if !defined $Item;
            next ITEM if $Item eq '';

            $DBObject->Do(
                SQL => 'INSERT INTO sms_event_item '
                    . '(sms_id, event_key, event_value) VALUES (?, ?, ?)',
                Bind => [ \$ID, \$Key, \$Item ],
            );
        }
    }

    return $ID;
}

=item SmsUpdate()

update a notification in database

    my $Ok = $NotificationEventObject->SmsUpdate(
        ID      => 123,
        Name    => 'JobName',
        Subject => 'JobName',
        Body    => 'JobName',
        Type    => 'text/plain',
        Charset => 'utf8',
        Data => {
            Queue => [ 'SomeQueue', ],
            ...
            Valid => [ 1, ],
        },
        UserID => 123,
    );

=cut

sub SmsUpdate {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(ID Name Subject Body Type Charset Data UserID)) {
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # fix some bad stuff from some browsers (Opera)!
    $Param{Body} =~ s/(\n\r|\r\r\n|\r\n|\r)/\n/g;

    # update data in db
    return if !$DBObject->Do(
        SQL => 'UPDATE sms_event SET '
            . 'name = ?, subject = ?, text = ?, content_type = ?, charset = ?, '
            . 'valid_id = ?, comments = ?, '
            . 'change_time = current_timestamp, change_by = ? WHERE id = ?',
        Bind => [
            \$Param{Name},    \$Param{Subject}, \$Param{Body},
            \$Param{Type},    \$Param{Charset}, \$Param{ValidID},
            \$Param{Comment}, \$Param{UserID},  \$Param{ID},
        ],
    );

    $DBObject->Do(
        SQL  => 'DELETE FROM sms_event_item WHERE sms_id = ?',
        Bind => [ \$Param{ID} ],
    );

    for my $Key ( sort keys %{ $Param{Data} } ) {

        ITEM:
        for my $Item ( @{ $Param{Data}->{$Key} } ) {

            next ITEM if !defined $Item;
            next ITEM if $Item eq '';

            $DBObject->Do(
                SQL => 'INSERT INTO sms_event_item '
                    . '(sms_id, event_key, event_value) VALUES (?, ?, ?)',
                Bind => [ \$Param{ID}, \$Key, \$Item ],
            );
        }
    }

    return 1;
}

=item SmsDelete ()

deletes an notification from the database

    $NotificationEventObject->SmsDelete (
        ID     => 123,
        UserID => 123,
    );

=cut

sub SmsDelete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(ID UserID)) {
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # check if job name exists
    my %Check = $Self->SmsGet( ID => $Param{ID} );
    if ( !%Check ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Can't delete notification '$Check{Name}', notification does not exist",
        );
        return;
    }

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # delete notification
    $DBObject->Do(
        SQL  => 'DELETE FROM sms_event_item WHERE sms_id = ?',
        Bind => [ \$Param{ID} ],
    );
    $DBObject->Do(
        SQL  => 'DELETE FROM sms_event WHERE id = ?',
        Bind => [ \$Param{ID} ],
    );

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'notice',
        Message  => "SmsEvent notification '$Check{Name}' deleted (UserID=$Param{UserID}).",
    );

    return 1;
}

=item NotificationEventCheck()

returns array of notification affected by event

    my @IDs = $NotificationEventObject->NotificationEventCheck( Event => 'ArticleCreate' );

=cut

sub SmsEventCheck  {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{Event} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need Name!'
        );
        return;
    }

    # get needed objects
    my $DBObject    = $Kernel::OM->Get('Kernel::System::DB');
    my $ValidObject = $Kernel::OM->Get('Kernel::System::Valid');

    $DBObject->Prepare(
        SQL => 'SELECT DISTINCT(nei.sms_id) FROM ' .
            'sms_event ne, sms_event_item nei WHERE ' .
            'ne.id = nei.sms_id AND ' .
            "ne.valid_id IN ( ${\(join ', ', $ValidObject->ValidIDsGet())} ) AND " .
            'nei.event_key = \'Events\' AND nei.event_value = ?',
        Bind => [ \$Param{Event} ],
    );

    my @IDs;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        push @IDs, $Row[0];
    }

    return @IDs;
}

1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
