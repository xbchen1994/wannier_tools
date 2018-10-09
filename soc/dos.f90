subroutine dos_sub
!> calculate density of state for 3D bulk system
!
!> DOS(\omega)= \sum_k \delta(\omega- E(k))

   use wmpi
   use para
   implicit none

   !> the integration k space
   real(dp) :: emin, emax

   real(dp) :: eta_brodening

   integer :: ik, ie, ib, ikx, iky, ikz, knv3, NE, ierr

   !> integration for band
   integer :: iband_low, iband_high, iband_tot

   real(dp) :: x, dk3, k(3)
   real(dp) :: time_start, time_end

   real(dp), allocatable :: eigval(:)
   real(dp), allocatable :: W(:)
   real(dp), allocatable :: omega(:)
   real(dp), allocatable :: dos(:)
   real(dp), allocatable :: dos_mpi(:)
   complex(dp), allocatable :: Hk(:, :)

   !> delta function
   real(dp), external :: delta

   knv3= Nk1*Nk2*Nk3

   if (OmegaNum<2) OmegaNum=2
   NE= OmegaNum

   iband_low= Numoccupied- 10000
   iband_high= Numoccupied+ 10000

   if (iband_low <1) iband_low = 1
   if (iband_high >Num_wann) iband_high = Num_wann

   iband_tot= iband_high- iband_low+ 1


   allocate(W(Num_wann))
   allocate(Hk(Num_wann, Num_wann))
   allocate(eigval(iband_tot))
   allocate(dos(NE))
   allocate(dos_mpi(NE))
   allocate(omega(NE))
   omega= 0d0
   Hk= 0d0
   W=0d0
   dos=0d0
   dos_mpi=0d0
   eigval= 0d0


   emin= OmegaMin
   emax= OmegaMax
   eta_brodening= (emax- emin)/ dble(NE)*6d0


   !> energy
   do ie=1, NE
      omega(ie)= emin+ (emax-emin)* (ie-1d0)/dble(NE-1)
   enddo ! ie

   dk3= kCubeVolume/dble(knv3)

   !> get eigenvalue
   time_start= 0d0
   time_end= 0d0
   do ik=1+cpuid, knv3, num_cpu

      if (cpuid.eq.0.and. mod(ik/num_cpu, 100).eq.0) &
         write(stdout, '(a, i18, "/", i18, a, f10.3, "s")') 'ik/knv3', &
         ik, knv3, 'time left', (knv3-ik)*(time_end-time_start)/num_cpu


      call now(time_start)
      ikx= (ik-1)/(nk2*nk3)+1
      iky= ((ik-1-(ikx-1)*Nk2*Nk3)/nk3)+1
      ikz= (ik-(iky-1)*Nk3- (ikx-1)*Nk2*Nk3)
      k= K3D_start_cube+ K3D_vec1_cube*(ikx-1)/dble(nk1)  &
       + K3D_vec2_cube*(iky-1)/dble(nk2)  &
       + K3D_vec3_cube*(ikz-1)/dble(nk3)

      !> get Hamiltonian at a given k point and diagonalize it
      call ham_bulk(k, Hk)
      W= 0d0
      call eigensystem_c( 'N', 'U', Num_wann ,Hk, W)
      eigval(:)= W(iband_low:iband_high)

      do ie= 1, NE
         do ib= 1, iband_tot
            x= omega(ie)- eigval(ib)
            dos_mpi(ie) = dos_mpi(ie)+ delta(eta_brodening, x)
         enddo ! ib
      enddo ! ie
      call now(time_end)

   enddo  ! ik

#if defined (MPI)
call mpi_allreduce(dos_mpi,dos,size(dos),&
                      mpi_dp,mpi_sum,mpi_cmw,ierr)
#else
   dos= dos_mpi
#endif
   dos= dos*dk3

   !> include the spin degeneracy if there is no SOC in the tight binding Hamiltonian.
   if (SOC<=0) dos=dos*2d0

   outfileindex= outfileindex+ 1
   if (cpuid.eq.0) then
      open(unit=outfileindex, file='dos.dat')
      write(outfileindex, *)'# Density of state of bulk system'
      write(outfileindex, '(2a16)')'# E(eV)', 'DOS(E) (1/eV/unit cell)'
      do ie=1, NE
         write(outfileindex, '(2f16.6)')omega(ie), dos(ie)
      enddo ! ie 
      close(outfileindex)
   endif
 
   outfileindex= outfileindex+ 1
   !> write script for gnuplot
   if (cpuid==0) then
      open(unit=outfileindex, file='dos.gnu')
      write(outfileindex, '(a)')"set encoding iso_8859_1"
      write(outfileindex, '(a)')'set terminal  postscript enhanced color font ",24" '
      write(outfileindex, '(a)')"set output 'dos.eps'"
      write(outfileindex, '(a)')'set border lw 2'
      write(outfileindex, '(a)')'set autoscale fix'
      write(outfileindex, '(a)')'set yrange [0:1]'
      write(outfileindex, '(a)')'unset key'
      write(outfileindex, '(a)')'set xlabel "Energy (eV)"'
      write(outfileindex, '(a)')'set ylabel "DOS (1/eV/unit cell)"'
      write(outfileindex, '(2a)')"plot 'dos.dat' u 1:2 w l lw 4 lc rgb 'black'"
      close(outfileindex)
   endif


   return
end subroutine dos_sub

subroutine joint_dos
! calculate joint density of state for 3D bulk system
!
! JDOS(\omega)= \sum_k (f_c(k)-f_v(k) \delta(\omega- Ec(k)+ Ev(k))

   use wmpi
   use para
   implicit none

   !> the integration k space
   real(dp) :: emin, emax

   integer :: ik, ie, ib, ib1, ib2
   integer :: ikx, iky, ikz, knv3, NE, ierr

   !> integration for band
   integer :: iband_low, iband_high, iband_tot

   real(dp) :: x, dk3

   real(dp) :: k(3)

   real(dp), allocatable :: kpoints(:, :), eigval(:, :), eigval_mpi(:, :)
   real(dp), allocatable :: W(:), omega(:), jdos(:), jdos_mpi(:)
   complex(dp), allocatable :: Hk(:, :)

   !> fermi distribution
   real(dp), allocatable :: fermi_dis(:, :)

   !> delta function
   real(dp), external :: delta

   knv3= Nk1*Nk2*Nk3

   NE= OmegaNum
   iband_low= Numoccupied- 10
   iband_high= Numoccupied+ 10

   if (iband_low <1) iband_low = 1
   if (iband_high >Num_wann) iband_high = Num_wann

   iband_tot= iband_high- iband_low+ 1


   allocate(jdos(NE))
   allocate(jdos_mpi(NE))
   allocate(omega(NE))
   allocate(W(Num_wann))
   allocate(kpoints(3, knv3))
   allocate(Hk(Num_wann, Num_wann))
   allocate(eigval(iband_tot, knv3))
   allocate(eigval_mpi(iband_tot, knv3))
   allocate(fermi_dis(iband_tot, knv3))
   W= 0d0
   Hk= 0d0
   eigval= 0d0
   eigval_mpi= 0d0
   fermi_dis= 0d0
   kpoints= 0d0
   jdos= 0d0
   jdos_mpi= 0d0
   omega= 0d0
 
   ik =0

   do ikx= 1, nk1
      do iky= 1, nk2
         do ikz= 1, nk3
            ik= ik+ 1
            kpoints(:, ik)= K3D_start_cube+ K3D_vec1_cube*(ikx-1)/dble(nk1)  &
                      + K3D_vec2_cube*(iky-1)/dble(nk2)  &
                      + K3D_vec3_cube*(ikz-1)/dble(nk3)
         enddo
      enddo
   enddo

   dk3= kCubeVolume/dble(knv3)

   !> get eigenvalue
   do ik=1+cpuid, knv3, num_cpu
      if (cpuid.eq.0) write(stdout, *) 'ik, knv3', ik, knv3
      k= kpoints(:, ik)
      call ham_bulk(k, Hk)
      W= 0d0
      call eigensystem_c( 'N', 'U', Num_wann ,Hk, W)
      eigval_mpi(:, ik)= W(iband_low:iband_high)
   enddo

#if defined (MPI)
   call mpi_allreduce(eigval_mpi,eigval,size(eigval),&
                      mpi_dp,mpi_sum,mpi_cmw,ierr)
#else
     eigval= eigval_mpi
#endif


   !> calculate fermi-dirac distribution
   do ik=1, knv3
      do ib=1, iband_tot
         if (eigval(ib, ik)<0) then
            fermi_dis(ib, ik)= 1d0
         else
            fermi_dis(ib, ik)= 0d0
         endif
      enddo
   enddo

   emin= 0d0
   emax= OmegaMax
   eta= (emax- emin)/ dble(NE)*3d0


   !> energy
   do ie=1, NE
      omega(ie)= emin+ (emax-emin)* (ie-1d0)/dble(NE-1)
   enddo ! ie

   !> get density of state
   jdos_mpi= 0d0
   do ie= 1, NE
      if (cpuid.eq.0) write(stdout, *)'ie, NE', ie, NE
      !> intergrate with k
      do ik= 1+cpuid, knv3, num_cpu
         do ib1= 1, iband_tot-1
            do ib2= ib1+1, iband_tot
               x= omega(ie)- eigval(ib2, ik) + eigval(ib1, ik)
               jdos_mpi(ie) = jdos_mpi(ie)+ delta(eta, x)* (fermi_dis(ib1, ik)- fermi_dis(ib2, ik))
            enddo ! ib2
         enddo ! ib1
      enddo ! ik
      jdos_mpi(ie)= jdos_mpi(ie)*dk3
   enddo ! ie

   jdos = 0d0
#if defined (MPI)
   call mpi_allreduce(jdos_mpi,jdos,size(jdos),&
                      mpi_dp,mpi_sum,mpi_cmw,ierr)
#else
     jdos= jdos_mpi
#endif

   outfileindex= outfileindex+ 1
   if (cpuid.eq.0) then
      open(unit=outfileindex, file='jdos.dat')
      do ie=1, NE
         write(outfileindex, *)omega(ie), jdos(ie)
      enddo ! ie 
      close(outfileindex)
   endif

 
   return
end subroutine joint_dos


subroutine dos_joint_dos
!  calculate density of state and joint density of state for 3D bulk system
!
!  JDOS(\omega)= \sum_k (f_c(k)-f_v(k) \delta(\omega- Ec(k)+ Ev(k))

   use wmpi
   use para
   implicit none

   !> the integration k space
   real(dp) :: emin, emax

   integer :: ik, ie, ib, ib1, ib2
   integer :: ikx, iky, ikz, knv3, NE, ierr

   !> integration for band
   integer :: iband_low, iband_high, iband_tot

   real(dp) :: x, dk3

   real(dp) :: k(3)
   real(dp), allocatable :: W(:), omega_dos(:), omega_jdos(:)
   real(dp), allocatable :: dos(:), dos_mpi(:), jdos(:), jdos_mpi(:), Hk(:, :)

   !> fermi distribution
   real(dp), allocatable :: fermi_dis(:)

   !> delta function
   real(dp), external :: delta

   knv3= Nk1*Nk2*Nk3

   NE= OmegaNum
   iband_low= Numoccupied- 40
   iband_high= Numoccupied+ 40

   if (iband_low <1) iband_low = 1
   if (iband_high >Num_wann) iband_high = Num_wann

   iband_tot= iband_high- iband_low+ 1


   allocate(dos(NE))
   allocate(dos_mpi(NE))
   allocate(jdos(NE))
   allocate(jdos_mpi(NE))
   allocate(omega_dos(NE))
   allocate(omega_jdos(NE))
   allocate(W(Num_wann))
   allocate(Hk(Num_wann, Num_wann))
   allocate(fermi_dis(Num_wann))
   W= 0d0
   Hk= 0d0
   fermi_dis= 0d0
   jdos= 0d0
   jdos_mpi= 0d0
   dos= 0d0
   dos_mpi= 0d0
   omega_dos= 0d0
   omega_jdos= 0d0
 

   dk3= kCubeVolume/dble(knv3)

   emin= 0d0
   emax= OmegaMax
   eta= (emax- emin)/ dble(NE)*5d0

   !> energy
   do ie=1, NE
      omega_jdos(ie)= emin+ (emax-emin)* (ie-1d0)/dble(NE-1)
   enddo ! ie

   emin= OmegaMin
   emax= OmegaMax

   !> energy
   do ie=1, NE
      omega_dos(ie)= emin+ (emax-emin)* (ie-1d0)/dble(NE-1)
   enddo ! ie


   !> get eigenvalue
   dos_mpi= 0d0
   jdos_mpi= 0d0
   do ik=1+cpuid, knv3, num_cpu
      if (cpuid.eq.0) write(stdout, *) 'ik, knv3', ik, knv3
      ikx= (ik- 1)/(Nk2*Nk3)+ 1
      iky= (ik- (ikx-1)*Nk2*Nk3- 1)/Nk3+ 1
      ikz= ik- (ikx-1)*Nk2*Nk3- (iky-1)*Nk3 

      k= K3D_start_cube+ K3D_vec1_cube*(ikx-1)/dble(nk1-1)  &
                + K3D_vec2_cube*(iky-1)/dble(nk2-1)  &
                + K3D_vec3_cube*(ikz-1)/dble(nk3-1)
      call ham_bulk(k, Hk)
      W= 0d0
      call eigensystem_c( 'N', 'U', Num_wann ,Hk, W)

      !> calculate fermi-dirac distribution
      do ib=iband_low, iband_high
         if (W(ib)<0) then
            fermi_dis(ib)= 1d0
         else
            fermi_dis(ib)= 0d0
         endif
      enddo !ib

      !> get density of state
      do ie= 1, NE
         do ib1= iband_low, iband_high-1
            do ib2= ib1+1, iband_high
               x= omega_jdos(ie)- W(ib2) + W(ib1)
               jdos_mpi(ie)= jdos_mpi(ie)+ delta(eta, x)* (fermi_dis(ib1)- fermi_dis(ib2))
            enddo ! ib2
         enddo ! ib1
      enddo ! ie

      !> get density of state
      do ie= 1, NE
         !> intergrate with k
         do ib= iband_low, iband_high-1
            x= omega_dos(ie)- W(ib)
            dos_mpi(ie) = dos_mpi(ie)+ delta(eta, x)
         enddo ! ib
      enddo ! ie

   enddo ! ik

#if defined (MPI)
   call mpi_allreduce(dos_mpi,dos,size(dos),&
                      mpi_dp,mpi_sum,mpi_cmw,ierr)
   call mpi_allreduce(jdos_mpi,jdos,size(jdos),&
                      mpi_dp,mpi_sum,mpi_cmw,ierr)
#else
     dos= dos_mpi
     jdos= jdos_mpi
#endif


   outfileindex= outfileindex+ 1
   if (cpuid.eq.0) then
      open(unit=outfileindex, file='jdos.dat')
      do ie=1, NE
         write(outfileindex, *)omega_jdos(ie), jdos(ie)*dk3
      enddo ! ie 
      close(outfileindex)
   endif

   outfileindex= outfileindex+ 1
   if (cpuid.eq.0) then
      open(unit=outfileindex, file='dos.dat')
      do ie=1, NE
         write(outfileindex, *)omega_dos(ie), dos(ie)*dk3
      enddo ! ie 
      close(outfileindex)
   endif
 
   return
end subroutine dos_joint_dos


function delta(eta, x)
   !>  Lorentz or Gaussian expansion of the Delta function
   use para, only : dp, pi
   implicit none
   real(dp), intent(in) :: eta
   real(dp), intent(in) :: x
   real(dp) :: delta, y

   !> lorentz brodening
  !delta= 1d0/pi*eta/(eta*eta+x*x)

   y= x*x/eta/eta/2d0

   !> Gaussian brodening
   !> exp(-60)=8.75651076269652e-27
   if (y>60) then
      delta= 0d0
   else
      delta= exp(-y)/sqrt(2d0*pi)/eta
   endif

   return
end function


