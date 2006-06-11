!
! Copyright (C) 2002-2005 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
SUBROUTINE move_ions()
  !----------------------------------------------------------------------------
  !
  ! ... This routine moves the ions according to the requested scheme:
  !
  ! ... lbfgs               bfgs minimizations
  ! ... lmd                 molecular dynamics ( verlet of vcsmd )
  ! ... lmd + lconstrain    constrained molecular dynamics,
  !
  ! ... coefficients for potential and wavefunctions extrapolation are
  ! ... also computed here
  !
  USE constants,              ONLY : eps8
  USE io_global,              ONLY : stdout
  USE io_files,               ONLY : tmp_dir, prefix, iunupdate
  USE kinds,                  ONLY : DP
  USE cell_base,              ONLY : alat, at, bg, omega
  USE cellmd,                 ONLY : omega_old, at_old, lmovecell, calc
  USE ions_base,              ONLY : nat, ityp, tau, if_pos
  USE gvect,                  ONLY : nr1, nr2, nr3
  USE symme,                  ONLY : s, ftau, nsym, irt
  USE ener,                   ONLY : etot
  USE force_mod,              ONLY : force
  USE control_flags,          ONLY : istep, nstep, upscale, lbfgs, ldamped, &
                                     lconstrain, lcoarsegrained, conv_ions, &
                                     lmd, history, tr2
  USE relax,                  ONLY : epse, epsf, starting_scf_threshold
  USE lsda_mod,               ONLY : lsda, absmag
  USE constraints_module,     ONLY : lagrange
  USE metadyn_vars,           ONLY : dfe_acc, etot_av, ncolvar
  USE metadyn_base,           ONLY : set_target
  USE mp_global,              ONLY : intra_image_comm
  USE io_global,              ONLY : ionode_id, ionode
  USE mp,                     ONLY : mp_bcast
  USE bfgs_module,            ONLY : bfgs, terminate_bfgs
  USE basic_algebra_routines, ONLY : norm
  USE dynamics_module,        ONLY : diff_coeff
  USE dynamics_module,        ONLY : verlet, proj_verlet
  !
  IMPLICIT NONE
  !
  LOGICAL, SAVE         :: lcheck_mag = .TRUE.
    ! .TRUE. if a check on zero absolute magnetization is required
  REAL(DP), ALLOCATABLE :: tauold(:,:,:)
  INTEGER               :: na  
  REAL(DP)              :: energy_error, gradient_error
  LOGICAL               :: step_accepted, exst
  REAL(DP), ALLOCATABLE :: pos(:), gradient(:)
  !
  !
  ! ... only one node does the calculation in the parallel case
  !
  IF ( ionode ) THEN 
     !
     conv_ions = .FALSE.
     !
     ALLOCATE( tauold( 3, nat, 3 ) )
     !
     ! ... the file containing old positions is opened 
     ! ... ( needed for extrapolation )
     !
     CALL seqopn( iunupdate, 'update', 'FORMATTED', exst ) 
     !
     IF ( exst ) THEN
        !
        READ( UNIT = iunupdate, FMT = * ) history
        READ( UNIT = iunupdate, FMT = * ) tauold
        !
     ELSE
        !
        history = 0
        tauold  = 0.D0
        !
        WRITE( UNIT = iunupdate, FMT = * ) history
        WRITE( UNIT = iunupdate, FMT = * ) tauold
        !
     END IF
     !
     CLOSE( UNIT = iunupdate, STATUS = 'KEEP' )
     !
     ! ... save the previous two steps ( a total of three steps is saved )
     !
     tauold(:,:,3) = tauold(:,:,2)
     tauold(:,:,2) = tauold(:,:,1)
     tauold(:,:,1) = tau(:,:)
     !
     ! ... history is updated (a new ionic step has been done)
     !
     history = MIN( 3, ( history + 1 ) )
     !
     ! ... old positions are written on file
     !
     CALL seqopn( iunupdate, 'update', 'FORMATTED', exst ) 
     !
     WRITE( UNIT = iunupdate, FMT = * ) history
     WRITE( UNIT = iunupdate, FMT = * ) tauold
     !
     CLOSE( UNIT = iunupdate, STATUS = 'KEEP' )
     !  
     DEALLOCATE( tauold )
     !
     ! ... do the minimization / dynamics step
     !
     IF ( lmovecell .AND. lconstrain ) &
        CALL errore( 'move_ions', &
                   & 'variable cell and constraints not implemented', 1 )
     !
     ! ... BFGS algorithm is used to minimize ionic configuration
     !
     IF ( lbfgs ) THEN
        !
        ! ... the bfgs procedure is used
        !  
        ALLOCATE( pos(      3*nat ) )
        ALLOCATE( gradient( 3*nat ) )
        !
        pos      =   RESHAPE( tau,   (/ 3 * nat /) ) * alat
        gradient = - RESHAPE( force, (/ 3 * nat /) )
        !
        CALL bfgs( pos, etot, gradient, tmp_dir, stdout, epse, epsf, &
                   energy_error, gradient_error, istep, nstep,       &
                   step_accepted, conv_ions )
        !
        IF ( conv_ions ) THEN
           !
           IF ( ( lsda .AND. ( absmag < eps8 ) .AND. lcheck_mag ) ) THEN
              !
              ! ... lsda relaxation :  a final configuration with zero 
              ! ...                    absolute magnetization has been found
              !
              ! ... here we check if it is really the minimum energy structure
              ! ... by performing a new scf iteration without any "electronic"
              ! ... history
              !
              WRITE( UNIT = stdout, FMT = 9010 )
              WRITE( UNIT = stdout, FMT = 9020 )
              !
              CALL hinit0()
              CALL potinit()
              CALL newd()
              CALL wfcinit()
              !
              ! ... this check is performed only once
              !
              lcheck_mag = .FALSE.
              !
              ! ... conv_ions is set to .FALSE. to perform a final scf cycle
              !
              conv_ions = .FALSE.
              ! 
           ELSE
              !
              CALL terminate_bfgs( etot, stdout, tmp_dir )
              !
           END IF   
           !
        ELSE
           !
           ! ... if a new bfgs step is done, new threshold is computed
           !
           IF ( step_accepted ) THEN
              !
              tr2  = starting_scf_threshold * &
                     MIN( 1.D0, ( energy_error / ( epse * upscale ) ), &
                                ( gradient_error / ( epsf * upscale ) ) )
              tr2  = MAX( ( starting_scf_threshold / upscale ), tr2 ) 
              !       
           END IF       
           !
           WRITE( stdout, '(5X,"new conv_thr",T30,"= ",F18.10,/)' ) tr2
           !
           ! ... the logical flag lcheck_mag is set again to .TRUE. (needed if 
           ! ... a new configuration with zero zero absolute magnetization is 
           ! ... identified in the following steps of the relaxation)
           !
           lcheck_mag = .TRUE.
           !
        END IF
        !   
        tau   =   RESHAPE( pos,      (/ 3, nat /) ) / alat
        force = - RESHAPE( gradient, (/ 3, nat /) )
        !
        CALL output_tau( conv_ions )
        !
        DEALLOCATE( pos )
        DEALLOCATE( gradient ) 
        !
     END IF
     !
     ! ... molecular dynamics schemes are used
     !
     IF ( lmd ) THEN
        !
        IF ( calc == ' ' ) THEN
           !
           ! ... Verlet dynamics
           !
           IF ( lcoarsegrained ) CALL set_target()
           !
           IF ( ldamped ) THEN
              !
              CALL proj_verlet() 
              !
           ELSE
              !
              CALL verlet()
              !
           END IF
           !
           IF ( lcoarsegrained ) THEN
              !
              etot_av = etot_av + etot
              !
              dfe_acc(:) = dfe_acc(:) - lagrange(1:ncolvar)
              !
           END IF
           !
        ELSE IF ( calc /= ' ' ) THEN
           !
           ! ... variable cell shape md
           !
           CALL vcsmd()
           !
        END IF
        !
     END IF
     !
     ! ... before leaving check that the new positions still transform
     ! ... according to the symmetry of the system.
     !
     CALL checkallsym( nsym, s, nat, tau, ityp, &
                       at, bg, nr1, nr2, nr3, irt, ftau )
     !
  END IF
  !  
  ! ... broadcast calculated quantities to all nodes
  !
  CALL mp_bcast( istep,     ionode_id, intra_image_comm )
  CALL mp_bcast( tau,       ionode_id, intra_image_comm )
  CALL mp_bcast( force,     ionode_id, intra_image_comm )
  CALL mp_bcast( tr2,       ionode_id, intra_image_comm )
  CALL mp_bcast( conv_ions, ionode_id, intra_image_comm )
  CALL mp_bcast( history,   ionode_id, intra_image_comm )
  !
  IF ( lmovecell ) THEN
     !
     CALL mp_bcast( at,        ionode_id, intra_image_comm )
     CALL mp_bcast( at_old,    ionode_id, intra_image_comm )
     CALL mp_bcast( omega,     ionode_id, intra_image_comm )
     CALL mp_bcast( omega_old, ionode_id, intra_image_comm )
     CALL mp_bcast( bg,        ionode_id, intra_image_comm )
     !
  END IF
  !
  IF ( lcoarsegrained ) THEN
     !
     CALL mp_bcast( lagrange, ionode_id, intra_image_comm )
     CALL mp_bcast( etot_av,  ionode_id, intra_image_comm )
     CALL mp_bcast( dfe_acc,  ionode_id, intra_image_comm )
     !
  END IF
  ! 
  RETURN
  !
9000 FORMAT(5X,'atom ',I3,' type ',I2,'   force = ',3F14.8) 
  !
9010 FORMAT( /5X,'lsda relaxation :  a final configuration with zero', &
           & /5X,'                   absolute magnetization has been found' )
9020 FORMAT( /5X,'the program is checking if it is really ', &
           &     'the minimum energy structure',             &
           & /5X,'by performing a new scf iteration ',       & 
           &     'without any "electronic" history' )               
  !
END SUBROUTINE move_ions
