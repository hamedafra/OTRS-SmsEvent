# --
# Copyright (C) 2001-2016 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Modules::AdminSmsEvent;

use strict;
use warnings;

our $ObjectManagerDisabled = 1;

use Kernel::System::VariableCheck qw(:all);
use Kernel::Language qw(Translatable);
use Kernel::System::SmsEvent;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $RichText     = $ConfigObject->Get('Frontend::RichText');
    my $DynamicField = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldListGet(
        Valid      => 1,
        ObjectType => ['Ticket'],
    );


    #if ( $RichText && !$ConfigObject->Get("Frontend::Admin::$Self->{Action}")->{RichText} ) {
        $RichText = 0;
    #}


    # set type for notifications
    my $NotificationType  = 'text/plain';
    if ($RichText) {
        $NotificationType  = 'text/html';
    }

    my $ParamObject             = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $LayoutObject            = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $SmsEventObject 		= $Kernel::OM->Get('Kernel::System::SmsEvent');
    my $BackendObject           = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');
    my $MainObject              = $Kernel::OM->Get('Kernel::System::Main');

    # get registered transport layers
    my %RegisteredTransports = %{ $Kernel::OM->Get('Kernel::Config')->Get('Notification::Transport') || {} };

    # ------------------------------------------------------------ #
    # change
    # ------------------------------------------------------------ #
    if ( $Self->{Subaction} eq 'Change' ) {

        # get notification id
        my $ID = $ParamObject->GetParam( Param => 'ID' ) || '';

        # get notification data
        my %Data = $SmsEventObject->SmsGet(
            ID => $ID,
        );

        my $Output = $LayoutObject->Header();
        $Output .= $LayoutObject->NavigationBar();
        $Self->_Edit(
            %Data,
            Action             => 'Change',
            RichText           => $RichText,
            DynamicFieldValues => $Data{Data},
        );
        $Output .= $LayoutObject->Output(
            TemplateFile => 'AdminSmsEvent',
            Data         => \%Param,
        );
        $Output .= $LayoutObject->Footer();

        return $Output;
    }

    # ------------------------------------------------------------ #
    # change action
    # ------------------------------------------------------------ #
    elsif ( $Self->{Subaction} eq 'ChangeAction' ) {

        # challenge token check for write action
        $LayoutObject->ChallengeTokenCheck();

        my %GetParam;
        for my $Parameter (
            qw(ID Subject Body Type Charset Name Comment ValidID Events ArticleSubjectMatch ArticleBodyMatch ArticleTypeID ArticleSenderTypeID Transports)
            )
        {
            $GetParam{$Parameter} = $ParamObject->GetParam( Param => $Parameter ) || '';
        }
        PARAMETER:
        for my $Parameter (
            qw(Recipients RecipientAgents RecipientGroups RecipientRoles
            Events StateID QueueID PriorityID LockID TypeID ServiceID SLAID
            CustomerID CustomerUserID
            ArticleTypeID ArticleSubjectMatch ArticleBodyMatch Gateway  ArticleAttachmentInclude
            ArticleSenderTypeID Transports OncePerDay SendOnOutOfOffice
            VisibleForAgent VisibleForAgentTooltip LanguageID AgentEnabledByDefault)
            )
        {
            my @Data = $ParamObject->GetArray( Param => $Parameter );
            next PARAMETER if !@Data;
            $GetParam{Data}->{$Parameter} = \@Data;
        }

        # get the subject and body for all languages
        for my $LanguageID ( @{ $GetParam{Data}->{LanguageID} } ) {

            my $Subject = $ParamObject->GetParam( Param => $LanguageID . '_Subject' ) || '';
            my $Body    = $ParamObject->GetParam( Param => $LanguageID . '_Body' )    || '';

            $GetParam{Message}->{$LanguageID} = {
                Subject     => $Subject,
                Body        => $Body,
                #ContentType => $ContentType,
            };

            # set server error flag if field is empty
            if ( !$Subject ) {
                $GetParam{ $LanguageID . '_SubjectServerError' } = "ServerError";
            }
            if ( !$Body ) {
                $GetParam{ $LanguageID . '_BodyServerError' } = "ServerError";
            }
        }

        # to store dynamic fields profile data
        my %DynamicFieldValues;

        # get Dynamic fields for search from web request
        # cycle trough the activated Dynamic Fields for this screen
        DYNAMICFIELD:
        for my $DynamicFieldConfig ( @{$DynamicField} ) {
            next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

            # extract the dynamic field value form the web request
            my $DynamicFieldValue = $BackendObject->SearchFieldValueGet(
                DynamicFieldConfig     => $DynamicFieldConfig,
                ParamObject            => $ParamObject,
                ReturnProfileStructure => 1,
                LayoutObject           => $LayoutObject,
            );

            # set the complete value structure in GetParam to store it later in the Notification Item
            if ( IsHashRefWithData($DynamicFieldValue) ) {

                # set search structure for display
                %DynamicFieldValues = ( %DynamicFieldValues, %{$DynamicFieldValue} );

                #make all values array refs
                for my $FieldName ( sort keys %{$DynamicFieldValue} ) {
                    if ( ref $DynamicFieldValue->{$FieldName} ne 'ARRAY' ) {
                        $DynamicFieldValue->{$FieldName} = [ $DynamicFieldValue->{$FieldName} ];
                    }
                }

                # store special structure for match
                $GetParam{Data} = { %{ $GetParam{Data} }, %{$DynamicFieldValue} };
            }
        }

        # get transport settings values
        if ( IsHashRefWithData( \%RegisteredTransports ) ) {

            TRANSPORT:
            for my $Transport ( sort keys %RegisteredTransports ) {

                next TRANSPORT if !IsHashRefWithData( $RegisteredTransports{$Transport} );
                next TRANSPORT if !$RegisteredTransports{$Transport}->{Module};

                if ( !$MainObject->Require( $RegisteredTransports{$Transport}->{Module}, Silent => 1 ) ) {
                    next TRANSPORT;
                }

                # get transport settings string from transport object
                $Kernel::OM->Get( $RegisteredTransports{$Transport}->{Module} )->TransportParamSettingsGet(
                    GetParam => \%GetParam,
                );
            }
        }

        # update
        my $Ok;
        my $ArticleFilterMissing;

        # checking if article filter exist if necessary
        if (
            grep { $_ eq 'ArticleCreate' || $_ eq 'ArticleSend' }
            @{ $GetParam{Data}->{Events} || [] }
            )
        {
            if (
                !$GetParam{ArticleTypeID}
                && !$GetParam{ArticleSenderTypeID}
                && $GetParam{ArticleSubjectMatch} eq ''
                && $GetParam{ArticleBodyMatch} eq ''
                )
            {
                $ArticleFilterMissing = 1;
            }
        }

        # required Article filter only on ArticleCreate and ArticleSend event
        # if isn't selected at least one of the article filter fields, notification isn't updated
        if ( !$ArticleFilterMissing ) {

            $Ok = $SmsEventObject->SmsUpdate(
                %GetParam,
		Charset => $LayoutObject->{UserCharset},
		Type => $NotificationType,
                UserID => $Self->{UserID},
            );
        }

        if ($Ok) {
            $Self->_Overview();
            my $Output = $LayoutObject->Header();
            $Output .= $LayoutObject->NavigationBar();
            $Output .= $LayoutObject->Notify( Info => Translatable('Notification updated!') );
            $Output .= $LayoutObject->Output(
                TemplateFile => 'AdminSmsEvent',
                Data         => \%Param,
            );
            $Output .= $LayoutObject->Footer();

            return $Output;
        }
        else {
            for my $Needed (qw(Name Events Transports)) {
                $GetParam{ $Needed . "ServerError" } = "";
                if ( $GetParam{$Needed} eq '' ) {
                    $GetParam{ $Needed . "ServerError" } = "ServerError";
                }
            }

            # define ServerError Class attribute if necessary
            $GetParam{ArticleTypeIDServerError}       = "";
            $GetParam{ArticleSenderTypeIDServerError} = "";
            $GetParam{ArticleSubjectMatchServerError} = "";
            $GetParam{ArticleBodyMatchServerError}    = "";

            if ($ArticleFilterMissing) {
                $GetParam{ArticleTypeIDServerError}       = "ServerError";
                $GetParam{ArticleSenderTypeIDServerError} = "ServerError";
                $GetParam{ArticleSubjectMatchServerError} = "ServerError";
                $GetParam{ArticleBodyMatchServerError}    = "ServerError";
            }

            my $Output = $LayoutObject->Header();
            $Output .= $LayoutObject->NavigationBar();
            $Output .= $LayoutObject->Notify( Priority => 'Error' );
            $Self->_Edit(
                %GetParam,
                Action             => 'Change',
                RichText           => $RichText,
                DynamicFieldValues => \%DynamicFieldValues,
            );
            $Output .= $LayoutObject->Output(
                TemplateFile => 'AdminSmsEvent',
                Data         => \%Param,
            );
            $Output .= $LayoutObject->Footer();

            return $Output;
        }
    }

    # ------------------------------------------------------------ #
    # add
    # ------------------------------------------------------------ #
    elsif ( $Self->{Subaction} eq 'Add' ) {

        my $Output = $LayoutObject->Header();
        $Output .= $LayoutObject->NavigationBar();
        $Self->_Edit(
            Action   => 'Add',
            RichText => $RichText,
        );
        $Output .= $LayoutObject->Output(
            TemplateFile => 'AdminSmsEvent',
            Data         => \%Param,
        );
        $Output .= $LayoutObject->Footer();

        return $Output;
    }

    # ------------------------------------------------------------ #
    # add action
    # ------------------------------------------------------------ #
    elsif ( $Self->{Subaction} eq 'AddAction' ) {

        # challenge token check for write action
        $LayoutObject->ChallengeTokenCheck();

        my %GetParam;
        for my $Parameter (
            qw(Name Subject Body Type Charset Comment ValidID Events ArticleSubjectMatch ArticleBodyMatch ArticleTypeID ArticleSenderTypeID Transports)
            )
        {
            $GetParam{$Parameter} = $ParamObject->GetParam( Param => $Parameter ) || '';
        }
        PARAMETER:
        for my $Parameter (
            qw(Recipients RecipientAgents RecipientRoles RecipientGroups Events StateID QueueID
            PriorityID LockID TypeID ServiceID SLAID CustomerID CustomerUserID
            ArticleTypeID ArticleSubjectMatch ArticleBodyMatch Gateway ArticleAttachmentInclude
            ArticleSenderTypeID Transports OncePerDay SendOnOutOfOffice
            VisibleForAgent VisibleForAgentTooltip LanguageID AgentEnabledByDefault)
            )
        {
            my @Data = $ParamObject->GetArray( Param => $Parameter );
            next PARAMETER if !@Data;
            $GetParam{Data}->{$Parameter} = \@Data;
        }

        # get the subject and body for all languages
        for my $LanguageID ( @{ $GetParam{Data}->{LanguageID} } ) {

            my $Subject = $ParamObject->GetParam( Param => $LanguageID . '_Subject' ) || '';
            my $Body    = $ParamObject->GetParam( Param => $LanguageID . '_Body' )    || '';

            $GetParam{Message}->{$LanguageID} = {
                Subject     => $Subject,
                Body        => $Body,
                #ContentType => $ContentType,
            };

            # set server error flag if field is empty
            if ( !$Subject ) {
                $GetParam{ $LanguageID . '_SubjectServerError' } = "ServerError";
            }
            if ( !$Body ) {
                $GetParam{ $LanguageID . '_BodyServerError' } = "ServerError";
            }
        }

        # to store dynamic fields profile data
        my %DynamicFieldValues;

        # get Dynamic fields for search from web request
        # cycle trough the activated Dynamic Fields for this screen
        DYNAMICFIELD:
        for my $DynamicFieldConfig ( @{$DynamicField} ) {
            next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

            # extract the dynamic field value form the web request
            my $DynamicFieldValue = $BackendObject->SearchFieldValueGet(
                DynamicFieldConfig     => $DynamicFieldConfig,
                ParamObject            => $ParamObject,
                ReturnProfileStructure => 1,
                LayoutObject           => $LayoutObject,
            );

            # set the complete value structure in GetParam to store it later in the Generic Agent Job
            if ( IsHashRefWithData($DynamicFieldValue) ) {

                # set search structure for display
                %DynamicFieldValues = ( %DynamicFieldValues, %{$DynamicFieldValue} );

                #make all values array refs
                for my $FieldName ( sort keys %{$DynamicFieldValue} ) {
                    if ( ref $DynamicFieldValue->{$FieldName} ne 'ARRAY' ) {
                        $DynamicFieldValue->{$FieldName} = [ $DynamicFieldValue->{$FieldName} ];
                    }
                }

                # store special structure for match
                $GetParam{Data} = { %{ $GetParam{Data} }, %{$DynamicFieldValue} };
            }
        }

        # get transport settings values
        if ( IsHashRefWithData( \%RegisteredTransports ) ) {

            TRANSPORT:
            for my $Transport ( sort keys %RegisteredTransports ) {

                next TRANSPORT if !IsHashRefWithData( $RegisteredTransports{$Transport} );
                next TRANSPORT if !$RegisteredTransports{$Transport}->{Module};

                if ( !$MainObject->Require( $RegisteredTransports{$Transport}->{Module}, Silent => 1 ) ) {
                    next TRANSPORT;
                }

                # get transport settings string from transport object
                $Kernel::OM->Get( $RegisteredTransports{$Transport}->{Module} )->TransportParamSettingsGet(
                    GetParam => \%GetParam,
                );
            }
        }

        # add
        my $ID;
        my $ArticleFilterMissing;

        # define ServerError Message if necessary
        if (
            grep { $_ eq 'ArticleCreate' || $_ eq 'ArticleSend' }
            @{ $GetParam{Data}->{Events} || [] }
            )
        {
            if (
                !$GetParam{ArticleTypeID}
                && !$GetParam{ArticleSenderTypeID}
                && $GetParam{ArticleSubjectMatch} eq ''
                && $GetParam{ArticleBodyMatch} eq ''
                )
            {
                $ArticleFilterMissing = 1;
            }
        }

        # required Article filter only on ArticleCreate and Article Send event
        # if isn't selected at least one of the article filter fields, notification isn't added
        if ( !$ArticleFilterMissing ) {
            $ID = $SmsEventObject->SmsAdd(
                %GetParam,
		Charset => $LayoutObject->{UserCharset},
		Type => $NotificationType,
                UserID => $Self->{UserID},
            );
        }

        if ( !$GetParam{Data}->{Transports} ) {
            $GetParam{TransportServerError} = "ServerError";
        }

        if ($ID) {
            $Self->_Overview();
            my $Output = $LayoutObject->Header();
            $Output .= $LayoutObject->NavigationBar();
            $Output .= $LayoutObject->Notify( Info => Translatable('Notification added!') );
            $Output .= $LayoutObject->Output(
                TemplateFile => 'AdminSmsEvent',
                Data         => \%Param,
            );
            $Output .= $LayoutObject->Footer();

            return $Output;
        }
        else {
            for my $Needed (qw(Name Events Transports)) {
                $GetParam{ $Needed . "ServerError" } = "";
                if ( $GetParam{$Needed} eq '' ) {
                    $GetParam{ $Needed . "ServerError" } = "ServerError";
                }
            }

            # checking if article filter exist if necessary
            $GetParam{ArticleTypeIDServerError}       = "";
            $GetParam{ArticleSenderTypeIDServerError} = "";
            $GetParam{ArticleSubjectMatchServerError} = "";
            $GetParam{ArticleBodyMatchServerError}    = "";

            if ($ArticleFilterMissing) {
                $GetParam{ArticleTypeIDServerError}       = "ServerError";
                $GetParam{ArticleSenderTypeIDServerError} = "ServerError";
                $GetParam{ArticleSubjectMatchServerError} = "ServerError";
                $GetParam{ArticleBodyMatchServerError}    = "ServerError";
            }

            my $Output = $LayoutObject->Header();
            $Output .= $LayoutObject->NavigationBar();
            $Output .= $LayoutObject->Notify( Priority => 'Error' );
            $Self->_Edit(
                %GetParam,
                Action             => 'Add',
                RichText           => $RichText,
                DynamicFieldValues => \%DynamicFieldValues,
            );
            $Output .= $LayoutObject->Output(
                TemplateFile => 'AdminSmsEvent',
                Data         => \%Param,
            );
            $Output .= $LayoutObject->Footer();

            return $Output;
        }
    }

    # ------------------------------------------------------------ #
    # delete
    # ------------------------------------------------------------ #
    if ( $Self->{Subaction} eq 'Delete' ) {

        # challenge token check for write action
        $LayoutObject->ChallengeTokenCheck();

        my %GetParam;
        for my $Parameter (qw(ID)) {
            $GetParam{$Parameter} = $ParamObject->GetParam( Param => $Parameter ) || '';
        }

        my $Delete = $SmsEventObject->SmsDelete(
            ID     => $GetParam{ID},
            UserID => $Self->{UserID},
        );
        if ( !$Delete ) {
            return $LayoutObject->ErrorScreen();
        }

        return $LayoutObject->Redirect( OP => "Action=$Self->{Action}" );
    }

    # ------------------------------------------------------------
    # overview
    # ------------------------------------------------------------
    else {
        $Self->_Overview();
        my $Output = $LayoutObject->Header();
        $Output .= $LayoutObject->NavigationBar();
        $Output .= $LayoutObject->Output(
            TemplateFile => 'AdminSmsEvent',
            Data         => \%Param,
        );
        $Output .= $LayoutObject->Footer();

        return $Output;
    }

}

sub _Edit {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    $LayoutObject->Block(
        Name => 'Overview',
        Data => \%Param,
    );

    $LayoutObject->Block( Name => 'ActionList' );
    $LayoutObject->Block( Name => 'ActionOverview' );

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get list type
    my $TreeView = 0;
    if ( $ConfigObject->Get('Ticket::Frontend::ListType') eq 'tree' ) {
        $TreeView = 1;
    }

    $Param{RecipientsStrg} = $LayoutObject->BuildSelection(
        Data => {
            AgentOwner              => Translatable('Agent who owns the ticket'),
            AgentResponsible        => Translatable('Agent who is responsible for the ticket'),
            AgentWatcher            => Translatable('All agents watching the ticket'),
            AgentWritePermissions   => Translatable('All agents with write permission for the ticket'),
            AgentMyQueues           => Translatable('All agents subscribed to the ticket\'s queue'),
            AgentMyServices         => Translatable('All agents subscribed to the ticket\'s service'),
            AgentMyQueuesMyServices => Translatable('All agents subscribed to both the ticket\'s queue and service'),
            Customer                => Translatable('Customer of the ticket'),
        },
        Name       => 'Recipients',
        Multiple   => 1,
        Size       => 8,
        SelectedID => $Param{Data}->{Recipients},
        Class      => 'Modernize W75pc',
    );

    my %AllAgents = $Kernel::OM->Get('Kernel::System::User')->UserList(
        Type  => 'Long',
        Valid => 1,
    );
    $Param{RecipientAgentsStrg} = $LayoutObject->BuildSelection(
        Data       => \%AllAgents,
        Name       => 'RecipientAgents',
        Multiple   => 1,
        Size       => 4,
        SelectedID => $Param{Data}->{RecipientAgents},
        Class      => 'Modernize W75pc',
    );

    my $GroupObject = $Kernel::OM->Get('Kernel::System::Group');

    $Param{RecipientGroupsStrg} = $LayoutObject->BuildSelection(
        Data       => { $GroupObject->GroupList( Valid => 1 ) },
        Size       => 6,
        Name       => 'RecipientGroups',
        Multiple   => 1,
        SelectedID => $Param{Data}->{RecipientGroups},
        Class      => 'Modernize W75pc',
    );
    $Param{RecipientRolesStrg} = $LayoutObject->BuildSelection(
        Data       => { $GroupObject->RoleList( Valid => 1 ) },
        Size       => 6,
        Name       => 'RecipientRoles',
        Multiple   => 1,
        SelectedID => $Param{Data}->{RecipientRoles},
        Class      => 'Modernize W75pc',
    );

    # Set class name for event string...
    my $EventClass = 'Validate_Required';
    if ( $Param{EventsServerError} ) {
        $EventClass .= ' ' . $Param{EventsServerError};
    }

    # Set class name for article type...
    my $ArticleTypeIDClass = '';
    if ( $Param{ArticleTypeIDServerError} ) {
        $ArticleTypeIDClass .= ' ' . $Param{ArticleTypeIDServerError};
    }

    # Set class name for article sender type...
    my $ArticleSenderTypeIDClass = '';
    if ( $Param{ArticleSenderTypeIDServerError} ) {
        $ArticleSenderTypeIDClass .= ' ' . $Param{ArticleSenderTypeIDServerError};
    }

    my %RegisteredEvents = $Kernel::OM->Get('Kernel::System::Event')->EventList(
        ObjectTypes => [ 'Ticket', 'Article', ],
    );

    my @Events;
    for my $ObjectType ( sort keys %RegisteredEvents ) {
        push @Events, @{ $RegisteredEvents{$ObjectType} || [] };
    }

    # Suppress these events because of danger of endless loops.
    my %EventBlacklist = (
        ArticleAgentNotification    => 1,
        ArticleCustomerNotification => 1,
    );

    @Events = grep { !$EventBlacklist{$_} } @Events;

    # Build the list...
    $Param{EventsStrg} = $LayoutObject->BuildSelection(
        Data       => \@Events,
        Name       => 'Events',
        Multiple   => 1,
        Size       => 10,
        Class      => $EventClass . ' Modernize W75pc',
        SelectedID => $Param{Data}->{Events},
    );

    $Param{StatesStrg} = $LayoutObject->BuildSelection(
        Data => {
            $Kernel::OM->Get('Kernel::System::State')->StateList(
                UserID => 1,
                Action => $Self->{Action},
            ),
        },
        Name       => 'StateID',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{Data}->{StateID},
        Class      => 'Modernize W75pc',
    );

    $Param{QueuesStrg} = $LayoutObject->AgentQueueListOption(
        Data               => { $Kernel::OM->Get('Kernel::System::Queue')->GetAllQueues(), },
        Size               => 5,
        Multiple           => 1,
        Name               => 'QueueID',
        TreeView           => $TreeView,
        SelectedIDRefArray => $Param{Data}->{QueueID},
        OnChangeSubmit     => 0,
        Class              => 'Modernize W75pc',
    );

    $Param{PrioritiesStrg} = $LayoutObject->BuildSelection(
        Data => {
            $Kernel::OM->Get('Kernel::System::Priority')->PriorityList(
                UserID => 1,
                Action => $Self->{Action},
            ),
        },
        Name       => 'PriorityID',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{Data}->{PriorityID},
        Class      => 'Modernize W75pc',
    );

    $Param{LocksStrg} = $LayoutObject->BuildSelection(
        Data => {
            $Kernel::OM->Get('Kernel::System::Lock')->LockList(
                UserID => 1,
                Action => $Self->{Action},
            ),
        },
        Name       => 'LockID',
        Multiple   => 1,
        Size       => 3,
        SelectedID => $Param{Data}->{LockID},
        Class      => 'Modernize W75pc',
    );

    # get valid list
    my %ValidList        = $Kernel::OM->Get('Kernel::System::Valid')->ValidList();
    my %ValidListReverse = reverse %ValidList;

    $Param{ValidOption} = $LayoutObject->BuildSelection(
        Data       => \%ValidList,
        Name       => 'ValidID',
        SelectedID => $Param{ValidID} || $ValidListReverse{valid},
        Class      => 'Modernize W50pc',
    );
    $LayoutObject->Block(
        Name => 'OverviewUpdate',
        Data => \%Param,
    );

    # shows header
    if ( $Param{Action} eq 'Change' ) {
        $LayoutObject->Block( Name => 'HeaderEdit' );
    }
    else {
        $LayoutObject->Block( Name => 'HeaderAdd' );
    }

    # build type string
    if ( $ConfigObject->Get('Ticket::Type') ) {
        my %Type = $Kernel::OM->Get('Kernel::System::Type')->TypeList(
            UserID => $Self->{UserID},
        );
        $Param{TypesStrg} = $LayoutObject->BuildSelection(
            Data        => \%Type,
            Name        => 'TypeID',
            SelectedID  => $Param{Data}->{TypeID},
            Sort        => 'AlphanumericValue',
            Size        => 3,
            Multiple    => 1,
            Translation => 0,
            Class       => 'Modernize W75pc',
        );
        $LayoutObject->Block(
            Name => 'OverviewUpdateType',
            Data => \%Param,
        );
    }

    # build service string
    if ( $ConfigObject->Get('Ticket::Service') ) {

        # get list type
        my %Service = $Kernel::OM->Get('Kernel::System::Service')->ServiceList(
            Valid        => 1,
            KeepChildren => $ConfigObject->Get('Ticket::Service::KeepChildren') // 0,
            UserID       => $Self->{UserID},
        );
        $Param{ServicesStrg} = $LayoutObject->BuildSelection(
            Data        => \%Service,
            Name        => 'ServiceID',
            SelectedID  => $Param{Data}->{ServiceID},
            Size        => 5,
            Multiple    => 1,
            Translation => 0,
            Max         => 200,
            TreeView    => $TreeView,
            Class       => 'Modernize W75pc',
        );
        my %SLA = $Kernel::OM->Get('Kernel::System::SLA')->SLAList(
            UserID => $Self->{UserID},
        );
        $Param{SLAsStrg} = $LayoutObject->BuildSelection(
            Data        => \%SLA,
            Name        => 'SLAID',
            SelectedID  => $Param{Data}->{SLAID},
            Sort        => 'AlphanumericValue',
            Size        => 5,
            Multiple    => 1,
            Translation => 0,
            Max         => 200,
            Class       => 'Modernize W75pc',
        );
        $LayoutObject->Block(
            Name => 'OverviewUpdateService',
            Data => \%Param,
        );
    }

    # create dynamic field HTML for set with historical data options
    my $PrintDynamicFieldsSearchHeader = 1;

    # cycle trough the activated Dynamic Fields for this screen
    my $DynamicField = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldListGet(
        Valid      => 1,
        ObjectType => ['Ticket'],
    );

    my $BackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    DYNAMICFIELD:
    for my $DynamicFieldConfig ( @{$DynamicField} ) {
        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

        # skip all dynamic fields that are not designed to be notification triggers
        my $IsSmsEventCondition = $BackendObject->HasBehavior(
            DynamicFieldConfig => $DynamicFieldConfig,
            Behavior           => 'IsSmsEventCondition',
        );

        next DYNAMICFIELD if !$IsSmsEventCondition;

        # get field HTML
        my $DynamicFieldHTML = $BackendObject->SearchFieldRender(
            DynamicFieldConfig     => $DynamicFieldConfig,
            Profile                => $Param{DynamicFieldValues} || {},
            LayoutObject           => $LayoutObject,
            ConfirmationCheckboxes => 1,
            UseLabelHints          => 0,
        );

        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldHTML);

        if ($PrintDynamicFieldsSearchHeader) {
            $LayoutObject->Block( Name => 'DynamicField' );
            $PrintDynamicFieldsSearchHeader = 0;
        }

        # output dynamic field
        $LayoutObject->Block(
            Name => 'DynamicFieldElement',
            Data => {
                Label => $DynamicFieldHTML->{Label},
                Field => $DynamicFieldHTML->{Field},
            },
        );
    }

    # add rich text editor
    if ( $Param{RichText} ) {

        # use height/width defined for this screen
        my $Config = $ConfigObject->Get("Frontend::Admin::$Self->{Action}");
        $Param{RichTextHeight} = $Config->{RichTextHeight} || 0;
        $Param{RichTextWidth}  = $Config->{RichTextWidth}  || 0;

        $LayoutObject->Block(
            Name => 'RichText',
            Data => \%Param,
        );
    }

    # get language ids from message parameter, use English if no message is given
    # make sure English is the first language
    my @LanguageIDs;
    if ( IsHashRefWithData( $Param{Message} ) ) {
        if ( $Param{Message}->{en} ) {
            push @LanguageIDs, 'en';
        }
        LANGUAGEID:
        for my $LanguageID ( sort keys %{ $Param{Message} } ) {
            next LANGUAGEID if $LanguageID eq 'en';
            push @LanguageIDs, $LanguageID;
        }
    }
    else {
        @LanguageIDs = ('en');
    }

    # get names of languages in English
    my %DefaultUsedLanguages = %{ $ConfigObject->Get('DefaultUsedLanguages') || {} };

    # get native names of languages
    my %DefaultUsedLanguagesNative = %{ $ConfigObject->Get('DefaultUsedLanguagesNative') || {} };

    my %Languages;
    LANGUAGEID:
    for my $LanguageID ( sort keys %DefaultUsedLanguages ) {

        # next language if there is not set any name for current language
        if ( !$DefaultUsedLanguages{$LanguageID} && !$DefaultUsedLanguagesNative{$LanguageID} ) {
            next LANGUAGEID;
        }

        # get texts in native and default language
        my $Text        = $DefaultUsedLanguagesNative{$LanguageID} || '';
        my $TextEnglish = $DefaultUsedLanguages{$LanguageID}       || '';

        # translate to current user's language
        my $TextTranslated =
            $Kernel::OM->Get('Kernel::Output::HTML::Layout')->{LanguageObject}->Translate($TextEnglish);

        if ( $TextTranslated && $TextTranslated ne $Text ) {
            $Text .= ' - ' . $TextTranslated;
        }

        # next language if there is not set English nor native name of language.
        next LANGUAGEID if !$Text;

        $Languages{$LanguageID} = $Text;
    }

    # copy original list of languages which will be used for rebuilding language selection
    my %OriginalDefaultUsedLanguages = %Languages;

    my $HTMLUtilsObject = $Kernel::OM->Get('Kernel::System::HTMLUtils');

    for my $LanguageID (@LanguageIDs) {

        # format the content according to the content type
        if ( $Param{RichText} ) {

            # make sure body is rich text (if body is based on config)
            if (
                $Param{Message}->{$LanguageID}->{ContentType}
                && $Param{Message}->{$LanguageID}->{ContentType} =~ m{text\/plain}xmsi
                )
            {
                $Param{Message}->{$LanguageID}->{Body} = $HTMLUtilsObject->ToHTML(
                    String => $Param{Message}->{$LanguageID}->{Body},
                );
            }
        }
        else {

            # reformat from HTML to plain
            if (
                $Param{Message}->{$LanguageID}->{ContentType}
                && $Param{Message}->{$LanguageID}->{ContentType} =~ m{text\/html}xmsi
                && $Param{Message}->{$LanguageID}->{Body}
                )
            {
                $Param{Message}->{$LanguageID}->{Body} = $HTMLUtilsObject->ToAscii(
                    String => $Param{Message}->{$LanguageID}->{Body},
                );
            }
        }

        # show the notification for this language
        $LayoutObject->Block(
            Name => 'NotificationLanguage',
            Data => {
                %Param,
                Subject => $Param{Message}->{$LanguageID}->{Subject} || '',
                Body    => $Param{Message}->{$LanguageID}->{Body}    || '',
                LanguageID         => $LanguageID,
                Language           => $Languages{$LanguageID},
                SubjectServerError => $Param{ $LanguageID . '_SubjectServerError' } || '',
                BodyServerError    => $Param{ $LanguageID . '_BodyServerError' } || '',
            },
        );

        # show the button to remove a notification only if it is not the English notification
        if ( $LanguageID ne 'en' ) {
            $LayoutObject->Block(
                Name => 'NotificationLanguageRemoveButton',
                Data => {
                    %Param,
                    LanguageID => $LanguageID,
                },
            );
        }

        # delete language from drop-down list because it is already shown
        delete $Languages{$LanguageID};
    }

    $Param{LanguageStrg} = $LayoutObject->BuildSelection(
        Data         => \%Languages,
        Name         => 'Language',
        Class        => 'Modernize W50pc LanguageAdd',
        Translation  => 1,
        PossibleNone => 1,
        HTMLQuote    => 0,
    );
    $Param{LanguageOrigStrg} = $LayoutObject->BuildSelection(
        Data         => \%OriginalDefaultUsedLanguages,
        Name         => 'LanguageOrig',
        Translation  => 1,
        PossibleNone => 1,
        HTMLQuote    => 0,
    );

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    $Param{ArticleTypesStrg} = $LayoutObject->BuildSelection(
        Data        => { $TicketObject->ArticleTypeList( Result => 'HASH' ), },
        Name        => 'ArticleTypeID',
        SelectedID  => $Param{Data}->{ArticleTypeID},
        Class       => $ArticleTypeIDClass . ' Modernize W75pc',
        Size        => 5,
        Multiple    => 1,
        Translation => 1,
        Max         => 200,
    );

    $Param{ArticleSenderTypesStrg} = $LayoutObject->BuildSelection(
        Data        => { $TicketObject->ArticleSenderTypeList( Result => 'HASH' ), },
        Name        => 'ArticleSenderTypeID',
        SelectedID  => $Param{Data}->{ArticleSenderTypeID},
        Class       => $ArticleSenderTypeIDClass . ' Modernize W75pc',
        Size        => 5,
        Multiple    => 1,
        Translation => 1,
        Max         => 200,
    );
	
  my %GwList;
    # COMPLEMENTO - Load list of Gateway Modules
    if ( ref $ConfigObject->Get('SmsEvent::Gateway') eq 'HASH' ) {
        my %Gws = %{ $ConfigObject->Get('SmsEvent::Gateway') };
        
        for my $Gw ( sort keys %Gws ) {
                $GwList{$Gw}=$Gws{$Gw}->{Name};
        }
    }

    $Param{GatewayStrg} = $LayoutObject->BuildSelection(
        Data        => \%GwList,
        Name        => 'Gateway',
        SelectedID  => $Param{Data}->{Gateway} || 0,
        Translation => 1,
        Max         => 200,
    );



    my %SmsArticleTypes = $TicketObject->ArticleTypeList( Result => 'HASH' );
    for my $SmsArticleTypeID ( sort keys %SmsArticleTypes  ) {
        if ( $SmsArticleTypes {$SmsArticleTypeID} !~ /sms/ ) {
            delete $SmsArticleTypes{$SmsArticleTypeID};
        }
    }


  $Param{NotificationArticleTypesStrg} = $LayoutObject->BuildSelection(
        Data        => \%SmsArticleTypes,
        Name        => 'SmsArticleTypeID',
        Translation => 1,
        SelectedID  => $Param{Data}->{SmsArticleTypeID},
);

    # take over data fields
    KEY:
    for my $Key (
        qw(VisibleForAgent VisibleForAgentTooltip CustomerID CustomerUserID ArticleSubjectMatch ArticleBodyMatch)
        )
    {
        next KEY if !$Param{Data}->{$Key};
        next KEY if !defined $Param{Data}->{$Key}->[0];
        $Param{$Key} = $Param{Data}->{$Key}->[0];
    }

    # set send on out of office checked value
    $Param{SendOnOutOfOfficeChecked} = ( $Param{Data}->{SendOnOutOfOffice} ? 'checked="checked"' : '' );

    # set once per day checked value
    $Param{OncePerDayChecked} = ( $Param{Data}->{OncePerDay} ? 'checked="checked"' : '' );

    $Param{VisibleForAgentStrg} = $LayoutObject->BuildSelection(
        Data => {
            0 => Translatable('No'),
            1 => Translatable('Yes'),
            2 => Translatable('Yes, but require at least one active notification method'),
        },
        Name       => 'VisibleForAgent',
        Sort       => 'NumericKey',
        Size       => 1,
        SelectedID => $Param{VisibleForAgent},
        Class      => 'Modernize W50pc',
    );

    # include read-only attribute
    if ( !$Param{VisibleForAgent} ) {
        $Param{VisibleForAgentTooltipReadonly} = 'readonly="readonly"';
    }

    # get registered transport layers
    my %RegisteredTransports = %{ $Kernel::OM->Get('Kernel::Config')->Get('Notification::Transport') || {} };

    if ( IsHashRefWithData( \%RegisteredTransports ) ) {

        my $MainObject         = $Kernel::OM->Get('Kernel::System::Main');
        my $OTRSBusinessObject = $Kernel::OM->Get('Kernel::System::OTRSBusiness');

        TRANSPORT:
        for my $Transport (
            sort { $RegisteredTransports{$a}->{Prio} <=> $RegisteredTransports{$b}->{Prio} }
            keys %RegisteredTransports
            )
        {

            next TRANSPORT if !IsHashRefWithData( $RegisteredTransports{$Transport} );
            next TRANSPORT if !$RegisteredTransports{$Transport}->{Module};

            # transport
            $LayoutObject->Block(
                Name => 'TransportRow',
                Data => {
                    Transport     => $Transport,
                    TransportName => $RegisteredTransports{$Transport}->{Name},
                },
            );

            if ( !$MainObject->Require( $RegisteredTransports{$Transport}->{Module}, Silent => 1 ) ) {

                # backend for this transport is not available
                $LayoutObject->Block(
                    Name => 'TransportRowDisabled',
                    Data => {
                        Transport     => $Transport,
                        TransportName => $RegisteredTransports{$Transport}->{Name},
                    },
                );

                # if not standard transport
                if (
                    defined $RegisteredTransports{$Transport}->{IsOTRSBusinessTransport}
                    && $RegisteredTransports{$Transport}->{IsOTRSBusinessTransport} eq '1'
                    && !$OTRSBusinessObject->OTRSBusinessIsInstalled()
                    )
                {

                    # transport
                    $LayoutObject->Block(
                        Name => 'TransportRowRecommendation',
                        Data => {
                            Transport     => $Transport,
                            TransportName => $RegisteredTransports{$Transport}->{Name},
                        },
                    );
                }

                next TRANSPORT;
            }
            else {
                my $TransportChecked = '';
                if ( grep { $_ eq $Transport } @{ $Param{Data}->{Transports} } ) {
                    $TransportChecked = 'checked="checked"';
                }

                # set Email transport selected on add screen
                if ( $Transport eq 'Email' && !$Param{ID} ) {
                    $TransportChecked = 'checked="checked"'
                }

                # get transport settings string from transport object
                my $TransportSettings =
                    $Kernel::OM->Get( $RegisteredTransports{$Transport}->{Module} )->TransportSettingsDisplayGet(
                    %Param,
                    );

                # it should decide if the default value for the
                # notification on AgentPreferences is enabled or not
                my $AgentEnabledByDefault = 0;
                if ( grep { $_ eq $Transport } @{ $Param{Data}->{AgentEnabledByDefault} } ) {
                    $AgentEnabledByDefault = 1;
                }
                elsif ( !$Param{ID} && defined $RegisteredTransports{$Transport}->{AgentEnabledByDefault} ) {
                    $AgentEnabledByDefault = $RegisteredTransports{$Transport}->{AgentEnabledByDefault};
                }
                my $AgentEnabledByDefaultChecked = ( $AgentEnabledByDefault ? 'checked="checked"' : '' );

                # transport
                $LayoutObject->Block(
                    Name => 'TransportRowEnabled',
                    Data => {
                        Transport                    => $Transport,
                        TransportName                => $RegisteredTransports{$Transport}->{Name},
                        TransportChecked             => $TransportChecked,
                        SettingsString               => $TransportSettings,
                        AgentEnabledByDefaultChecked => $AgentEnabledByDefaultChecked,
                        TransportsServerError        => $Param{TransportsServerError},
                    },
                );

            }

        }
    }
    else {

        # no transports
        $LayoutObject->Block(
            Name => 'NoDataFoundMsgTransport',
        );
    }

    return 1;
}

sub _Overview {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    $LayoutObject->Block(
        Name => 'Overview',
        Data => \%Param,
    );

    $LayoutObject->Block( Name => 'ActionList' );
    $LayoutObject->Block( Name => 'ActionAdd' );
    $LayoutObject->Block( Name => 'ActionImport' );

    $LayoutObject->Block(
        Name => 'OverviewResult',
        Data => \%Param,
    );

    my $SmsEventObject = $Kernel::OM->Get('Kernel::System::SmsEvent');

    my %List = $SmsEventObject->SmsList();

    # if there are any notifications, they are shown
    if (%List) {

        # get valid list
        my %ValidList = $Kernel::OM->Get('Kernel::System::Valid')->ValidList();
        for ( sort { $List{$a} cmp $List{$b} } keys %List ) {

            my %Data = $SmsEventObject->SmsGet(
                ID => $_,
            );
            $LayoutObject->Block(
                Name => 'OverviewResultRow',
                Data => {
                    Valid => $ValidList{ $Data{ValidID} },
                    %Data,
                },
            );
        }
    }

    # otherwise a no data found message is displayed
    else {
        $LayoutObject->Block(
            Name => 'NoDataFoundMsg',
            Data => {},
        );
    }

    return 1;
}

1;
